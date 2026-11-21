// tests/toolchain_pins.zig — static regression guards for the repo's
// toolchain pins (odd/tasks/zig-0.17.1-toolchain-bump.md, T-7).
//
// Specs covered
//   S1 — the four toolchain pin sites declare ONE agreed Zig version.
//   S3 — no functional surface mentions the retired `gga` tool.
//   S4 — the README declares a single toolchain for the current code.
//   S5 — tools/local-ci.sh compares the CI image's Zig against the pin.
//
// Why this file exists (spec L22): the 0.17.1 bump uncovered that the repo
// could *declare* 0.17.1 while the CI *verified* 0.17.0, and nothing inside
// the repo detected that divergence. These guards close the hole.
//
// Design rules
//   * Version-agnostic on purpose: the guards compare the pins against EACH
//     OTHER and against the README, never against a hardcoded literal, so the
//     next toolchain bump does not require editing this file.
//   * The guards read repo files relative to the process working directory,
//     which is the repo root when the test runs under `zig build` (the build
//     step sets cwd = repo root). A missing or unreadable file is a loud
//     failure — never a silent pass.
//   * S3 is a zero-mention rule, the same operational definition the feature
//     doc used to verify T-3 (spec L9: "no hay mención de `gga` en
//     `.github/`, `tools/`, `src/`, `tests/` ni `build.zig*`"). The token is
//     matched on word boundaries, so the substring false positives the spec
//     itself lists ("Plu**gga**ble") do not trip the guard.
//   * S5 compares the local CI script against its *code* only: a comparison
//     that lives in a comment is not a guard.
//   * Every helper uses an explicit error set (never `anyerror`), bounded
//     static buffers and no allocation outside the test bodies.

const std = @import("std");
const testing = std.testing;

/// Upper bound for any repo file this guard reads.
const max_file_bytes: usize = 1 << 20;

/// Maximum length of a version literal accepted by the guard.
const max_version_bytes: usize = 32;

/// Maximum number of pin declarations accepted in a single file.
const max_pins_per_file: usize = 16;

/// Maximum number of pin declarations accepted across all pin sites.
const max_total_pins: usize = 4 * max_pins_per_file;

/// Maximum number of "Zig <version>" mentions accepted in one document.
const max_mentions: usize = 64;

/// Explicit error set of the guard helpers (never `anyerror`).
pub const GuardError = error{
    /// A required pin declaration was not found where it belongs.
    PinNotFound,
    /// A pin declaration does not carry a `MAJOR.MINOR.PATCH` literal.
    MalformedVersion,
    /// Two pin declarations declare different versions.
    PinsDisagree,
    /// A file declares more pins than the guard accepts.
    TooManyPins,
    /// A document mentions more toolchain versions than the guard accepts.
    TooManyMentions,
    /// The README mentions a toolchain that is not the pinned one.
    ToolchainMismatch,
    /// A functional surface mentions the retired `gga` tool.
    GgaMentionFound,
    /// tools/local-ci.sh does not compare the image's Zig against the pin.
    StaleImageGuardMissing,
} || std.Io.Dir.ReadFileAllocError;

// ─────────────────────────────────────────────────────────────────────────────
// Version model
// ─────────────────────────────────────────────────────────────────────────────

/// A `MAJOR.MINOR.PATCH` version literal, e.g. `0.17.1`.
const Version = struct {
    major: u32,
    minor: u32,
    patch: u32,

    /// Parses a strict `MAJOR.MINOR.PATCH` literal.
    fn parse(text: []const u8) GuardError!Version {
        var it = std.mem.splitScalar(u8, text, '.');
        const major_text = it.next() orelse return error.MalformedVersion;
        const minor_text = it.next() orelse return error.MalformedVersion;
        const patch_text = it.next() orelse return error.MalformedVersion;
        if (it.next() != null) return error.MalformedVersion;
        return .{
            .major = try parseDecimal(major_text),
            .minor = try parseDecimal(minor_text),
            .patch = try parseDecimal(patch_text),
        };
    }

    /// True when both versions describe the same release.
    fn eql(a: Version, b: Version) bool {
        return a.major == b.major and a.minor == b.minor and a.patch == b.patch;
    }

    /// The `MAJOR.MINOR` family of the version — the granularity the prose
    /// of the documentation uses ("written in Zig 0.17").
    fn family(a: Version) Family {
        return .{ .major = a.major, .minor = a.minor };
    }
};

/// A `MAJOR.MINOR` family, e.g. `0.17`.
const Family = struct {
    major: u32,
    minor: u32,

    /// True when both families describe the same minor release line.
    fn eql(a: Family, b: Family) bool {
        return a.major == b.major and a.minor == b.minor;
    }
};

/// Parses a non-empty run of ASCII digits. Rejects signs, spaces and
/// anything that is not a digit — a pin must be a plain literal.
fn parseDecimal(text: []const u8) GuardError!u32 {
    if (text.len == 0) return error.MalformedVersion;
    var value: u32 = 0;
    for (text) |c| {
        if (c < '0' or c > '9') return error.MalformedVersion;
        const digit: u32 = c - '0';
        // Overflow guard: keep the accumulator below `maxInt(u32) / 10`.
        if (value > (std.math.maxInt(u32) - digit) / 10) return error.MalformedVersion;
        value = value * 10 + digit;
    }
    return value;
}

// ─────────────────────────────────────────────────────────────────────────────
// Repo file access
// ─────────────────────────────────────────────────────────────────────────────

/// Reads a repo file relative to the working directory (the repo root when
/// the test runs under `zig build`). A missing or unreadable file is a loud
/// failure — the guard never degrades into a silent pass.
fn readRepoFile(path: []const u8) GuardError![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(
        testing.io,
        path,
        testing.allocator,
        .limited(max_file_bytes),
    );
}

// ─────────────────────────────────────────────────────────────────────────────
// S1 — the toolchain pins
// ─────────────────────────────────────────────────────────────────────────────

/// The syntax a file uses to declare its toolchain pin.
const PinSyntax = enum {
    /// `.minimum_zig_version = "0.17.1"` — Zig Object Notation.
    zon_equals_quoted,
    /// `ZIG_VERSION: 0.17.1` — YAML.
    yaml_colon,
    /// `readonly ZIG_VERSION="0.17.1"` — POSIX shell.
    shell_equals_quoted,
    /// `ARG ZIG_VERSION=0.17.1` — Containerfile.
    containerfile_equals,
};

/// One toolchain pin site of the repo (spec S1).
const PinSite = struct {
    /// Repo-relative path of the file that declares the pin.
    path: []const u8,
    /// Human label used in the assertion messages.
    label: []const u8,
    /// The syntax the declaration uses.
    syntax: PinSyntax,
};

/// The four toolchain pin sites of the repo (spec S1).
const pin_sites = [_]PinSite{
    .{
        .path = "build.zig.zon",
        .label = "build.zig.zon (.minimum_zig_version)",
        .syntax = .zon_equals_quoted,
    },
    .{
        .path = ".github/workflows/ci.yml",
        .label = ".github/workflows/ci.yml (env.ZIG_VERSION)",
        .syntax = .yaml_colon,
    },
    .{
        .path = "tools/local-ci.sh",
        .label = "tools/local-ci.sh (ZIG_VERSION)",
        .syntax = .shell_equals_quoted,
    },
    .{
        .path = "tools/zargeant-ci.Containerfile",
        .label = "tools/zargeant-ci.Containerfile (ARG ZIG_VERSION)",
        .syntax = .containerfile_equals,
    },
};

/// A pin declaration found in a file. The version text is copied into a
/// fixed buffer so it stays valid after the file contents are released.
const SitePin = struct {
    /// Index into `pin_sites` of the file that declared the pin.
    site_index: usize,
    /// 1-based line number of the declaration.
    line: usize,
    /// The parsed version.
    version: Version,
    /// Backing storage for the raw version text.
    storage: [max_version_bytes]u8 = undefined,
    /// Number of valid bytes in `storage`.
    len: usize = 0,

    /// The raw version text as written in the file.
    fn text(self: *const SitePin) []const u8 {
        return self.storage[0..self.len];
    }
};

/// Extracts the version literal a pin declaration carries, or null when the
/// line is not a pin declaration at all.
fn pinValue(line: []const u8, syntax: PinSyntax) ?[]const u8 {
    const trimmed = std.mem.trim(u8, line, " \t\r");
    return switch (syntax) {
        .zon_equals_quoted => blk: {
            const key = ".minimum_zig_version";
            if (!std.mem.startsWith(u8, trimmed, key)) break :blk null;
            const rest = std.mem.trim(u8, trimmed[key.len..], " \t");
            if (rest.len == 0 or rest[0] != '=') break :blk null;
            const after = std.mem.trimStart(u8, rest[1..], " \t");
            if (after.len < 2 or after[0] != '"') break :blk null;
            const end = std.mem.findScalar(u8, after[1..], '"') orelse break :blk null;
            break :blk after[1 .. 1 + end];
        },
        .yaml_colon => blk: {
            const key = "ZIG_VERSION:";
            if (!std.mem.startsWith(u8, trimmed, key)) break :blk null;
            const value = std.mem.trim(u8, trimmed[key.len..], " \t");
            if (value.len == 0) break :blk null;
            // A template reference (`${{ env.ZIG_VERSION }}`) is not a literal.
            if (std.mem.find(u8, value, "${{") != null) break :blk null;
            break :blk value;
        },
        .shell_equals_quoted => blk: {
            var rest = trimmed;
            if (std.mem.startsWith(u8, rest, "readonly ")) {
                rest = std.mem.trimStart(u8, rest["readonly ".len..], " \t");
            }
            const key = "ZIG_VERSION=";
            if (!std.mem.startsWith(u8, rest, key)) break :blk null;
            const after = rest[key.len..];
            if (after.len < 2 or after[0] != '"') break :blk null;
            const end = std.mem.findScalar(u8, after[1..], '"') orelse break :blk null;
            break :blk after[1 .. 1 + end];
        },
        .containerfile_equals => blk: {
            const key = "ARG ZIG_VERSION=";
            if (!std.mem.startsWith(u8, trimmed, key)) break :blk null;
            break :blk std.mem.trim(u8, trimmed[key.len..], " \t");
        },
    };
}

/// Collects every pin declaration of `content` into `out`.
/// Returns the number of declarations found.
fn collectPins(
    content: []const u8,
    syntax: PinSyntax,
    out: *[max_pins_per_file]SitePin,
    site_index: usize,
) GuardError!usize {
    var count: usize = 0;
    var line_no: usize = 0;
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        line_no += 1;
        const raw = pinValue(line, syntax) orelse continue;
        if (count >= max_pins_per_file) return error.TooManyPins;
        if (raw.len > max_version_bytes) return error.MalformedVersion;
        const version = Version.parse(raw) catch |err| {
            std.debug.print(
                "\n[S1] {s}:{d}: '{s}' is not a MAJOR.MINOR.PATCH literal\n",
                .{ pin_sites[site_index].path, line_no, raw },
            );
            return err;
        };
        out[count] = .{
            .site_index = site_index,
            .line = line_no,
            .version = version,
            .len = raw.len,
        };
        @memcpy(out[count].storage[0..raw.len], raw);
        count += 1;
    }
    return count;
}

/// Collects every pin declaration of every pin site into `out`.
fn collectAllPins(out: *[max_total_pins]SitePin) GuardError!usize {
    var total: usize = 0;
    for (pin_sites, 0..) |site, site_index| {
        const content = try readRepoFile(site.path);
        defer testing.allocator.free(content);

        var pins: [max_pins_per_file]SitePin = undefined;
        const count = try collectPins(content, site.syntax, &pins, site_index);
        if (count == 0) {
            std.debug.print(
                "\n[S1] {s} declares no toolchain pin (expected {s})\n",
                .{ site.path, site.label },
            );
            return error.PinNotFound;
        }
        for (pins[0..count]) |pin| {
            if (total >= max_total_pins) return error.TooManyPins;
            out[total] = pin;
            total += 1;
        }
    }
    return total;
}

/// The version every pin site of the repo agrees on.
fn agreedPinVersion() GuardError!Version {
    var pins: [max_total_pins]SitePin = undefined;
    const total = try collectAllPins(&pins);
    if (total == 0) return error.PinNotFound;

    const agreed = pins[0].version;
    for (pins[0..total]) |pin| {
        if (pin.version.eql(agreed)) continue;
        std.debug.print(
            "\n[S1] {s}:{d} pins Zig {s}, but {s} pins Zig {s}\n",
            .{
                pin_sites[pin.site_index].path,
                pin.line,
                pin.text(),
                pin_sites[pins[0].site_index].path,
                pins[0].text(),
            },
        );
        return error.PinsDisagree;
    }
    return agreed;
}

test "S1: the four toolchain pin sites declare the same Zig version" {
    var pins: [max_total_pins]SitePin = undefined;
    const total = try collectAllPins(&pins);
    // Every one of the four sites must have contributed a pin.
    try testing.expect(total >= pin_sites.len);

    const agreed = pins[0].version;
    for (pin_sites, 0..) |site, site_index| {
        var seen: usize = 0;
        for (pins[0..total]) |pin| {
            if (pin.site_index != site_index) continue;
            seen += 1;
            if (pin.version.eql(agreed)) continue;
            std.debug.print(
                "\n[S1] {s}:{d} pins Zig {s}, but {s} pins Zig {s}\n",
                .{
                    site.path,
                    pin.line,
                    pin.text(),
                    pin_sites[pins[0].site_index].path,
                    pins[0].text(),
                },
            );
            return error.PinsDisagree;
        }
        try testing.expect(seen > 0);
    }
}

test "S1: no pin site keeps a version other than the agreed one" {
    var pins: [max_total_pins]SitePin = undefined;
    const total = try collectAllPins(&pins);
    const agreed = pins[0].version;

    // A file that declares a second, divergent pin (for example a stale
    // `ZIG_VERSION=` further down a script) must not slip through.
    for (pins[0..total]) |pin| {
        if (pin.version.eql(agreed)) continue;
        std.debug.print(
            "\n[S1] {s}:{d} pins Zig {s}, but the agreed version is Zig {d}.{d}.{d}\n",
            .{
                pin_sites[pin.site_index].path,
                pin.line,
                pin.text(),
                agreed.major,
                agreed.minor,
                agreed.patch,
            },
        );
        return error.PinsDisagree;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// S3 — the retired `gga` tool
// ─────────────────────────────────────────────────────────────────────────────

/// The comment syntax of the file the guard scans.
const Syntax = enum {
    /// `#` line comments (shell, YAML, Containerfile, justfile, gitignore).
    hash,
};

/// A functional surface that must not mention the retired `gga` tool.
const GgaSurface = struct {
    /// Repo-relative path of the file.
    path: []const u8,
};

/// The functional surfaces of the repo (spec S3).
const gga_surfaces = [_]GgaSurface{
    .{ .path = ".github/workflows/ci.yml" },
    .{ .path = ".github/PULL_REQUEST_TEMPLATE.md" },
    .{ .path = "tools/local-ci.sh" },
    .{ .path = "tools/zargeant-ci.Containerfile" },
    .{ .path = "build.zig" },
    .{ .path = "build.zig.zon" },
    .{ .path = ".gitignore" },
    .{ .path = "justfile" },
};

/// True for the bytes that may not be adjacent to a standalone token.
fn isWordChar(c: u8) bool {
    return (c >= 'a' and c <= 'z') or
        (c >= 'A' and c <= 'Z') or
        (c >= '0' and c <= '9') or
        c == '_';
}

fn isLowerG(c: u8) bool {
    return c == 'g' or c == 'G';
}

fn isLowerA(c: u8) bool {
    return c == 'a' or c == 'A';
}

/// Returns the code-only view of a `#`-commented script: every comment byte
/// is replaced by a space. Byte offsets are preserved, so a hit still maps
/// back to its original line.
///
/// String literals are kept verbatim (a token inside a string can still be
/// executed), and a quote only opens a string when it is closed on the same
/// line. An unbalanced quote is therefore treated as an ordinary character
/// instead of masking the rest of the file.
fn commentMask(
    allocator: std.mem.Allocator,
    content: []const u8,
    syntax: Syntax,
) GuardError![]u8 {
    std.debug.assert(syntax == .hash);
    const mask = try allocator.alloc(u8, content.len);
    errdefer allocator.free(mask);
    @memcpy(mask, content);

    var i: usize = 0;

    while (i < content.len) {
        const c = content[i];
        switch (syntax) {
            .hash => {
                if (c == '#') {
                    i = blankToEol(mask, content, i);
                    continue;
                }
            },
        }
        // A quoted span: skip it whole, so a comment marker inside it is
        // not mistaken for a comment.
        if (c == '"' or (syntax == .hash and c == '\'')) {
            if (closingQuote(content, i, c)) |end| {
                i = end + 1;
                continue;
            }
        }
        i += 1;
    }
    return mask;
}

/// Finds the quote that closes the quoted span opened at `start`.
/// Only a quote on the same line closes the span, so an unbalanced quote
/// never masks the rest of the file.
fn closingQuote(content: []const u8, start: usize, quote: u8) ?usize {
    std.debug.assert(start < content.len);
    std.debug.assert(content[start] == quote);
    var i = start + 1;
    while (i < content.len and content[i] != '\n') : (i += 1) {
        if (content[i] == '\\') {
            i += 1;
            continue;
        }
        if (content[i] == quote) return i;
    }
    return null;
}

/// Blanks `content[from..]` up to (not including) the next newline.
fn blankToEol(mask: []u8, content: []const u8, from: usize) usize {
    var j = from;
    while (j < content.len and content[j] != '\n') : (j += 1) mask[j] = ' ';
    return j;
}

/// Byte offset of the first standalone `gga` token inside `content`, or null.
/// "Standalone" means the token is not part of a longer identifier, so
/// "pluggable" and "aggregation" do not match.
fn findGgaToken(content: []const u8) ?usize {
    return findGgaTokenFrom(content, 0);
}

/// Byte offset of the first standalone `gga` token at or after `from`.
fn findGgaTokenFrom(content: []const u8, from: usize) ?usize {
    var i = from;
    while (i + 2 < content.len) : (i += 1) {
        if (!isLowerG(content[i])) continue;
        if (!isLowerG(content[i + 1])) continue;
        if (!isLowerA(content[i + 2])) continue;
        if (i > 0 and isWordChar(content[i - 1])) continue;
        if (i + 3 < content.len and isWordChar(content[i + 3])) continue;
        return i;
    }
    return null;
}

/// The 1-based line number of `offset` inside `content`.
fn lineOf(content: []const u8, offset: usize) usize {
    std.debug.assert(offset <= content.len);
    var line: usize = 1;
    for (content[0..offset]) |c| {
        if (c == '\n') line += 1;
    }
    return line;
}

/// The text of the line that holds `offset`.
fn lineText(content: []const u8, offset: usize) []const u8 {
    std.debug.assert(offset <= content.len);
    const start = if (std.mem.lastIndexOfScalar(u8, content[0..offset], '\n')) |idx| idx + 1 else 0;
    const end = std.mem.indexOfScalarPos(u8, content, start, '\n') orelse content.len;
    return std.mem.trim(u8, content[start..end], " \t\r");
}

test "S3: no functional surface mentions the retired gga tool" {
    var hits: usize = 0;
    for (gga_surfaces) |surface| {
        const content = try readRepoFile(surface.path);
        defer testing.allocator.free(content);

        var from: usize = 0;
        while (findGgaTokenFrom(content, from)) |offset| {
            std.debug.print(
                "\n[S3] {s} mentions 'gga' at line {d}:\n    {s}\n",
                .{ surface.path, lineOf(content, offset), lineText(content, offset) },
            );
            hits += 1;
            from = offset + 1;
        }
    }
    if (hits > 0) return error.GgaMentionFound;
}

test "S3: the gga scan matches the tool name but not longer identifiers" {
    // The scan must not become a no-op: the tool name has to be detected
    // wherever it names the tool.
    const hits = [_][]const u8{
        "run: gga check",
        "    const cmd = \"gga --version\";",
        "path = \".gga\";",
        "GGA=1",
    };
    for (hits) |sample| {
        if (findGgaToken(sample) == null) {
            std.debug.print("\n[S3] the scan missed '{s}'\n", .{sample});
            return error.GgaMentionFound;
        }
    }

    // The substring false positives the feature doc lists (L9) must not
    // trip the guard: "Plu**gga**ble" and "aggre**gga**tion".
    const misses = [_][]const u8{
        "pub fn pluggable() void {}",
        "const aggregation = 1;",
    };
    for (misses) |sample| {
        if (findGgaToken(sample) != null) {
            std.debug.print("\n[S3] the scan false-positived on '{s}'\n", .{sample});
            return error.GgaMentionFound;
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// S4 — the README declares a single toolchain
// ─────────────────────────────────────────────────────────────────────────────

/// The README path (repo-relative).
const readme_path = "README.md";

/// The historical document whose Zig 0.16 references the README is allowed
/// to keep (spec L7: the two mentions describe the *content* of that doc).
const historical_doc = "investigation-2.md";

/// A "Zig <version>" mention found in a document.
const VersionMention = struct {
    /// 1-based line number of the mention.
    line: usize,
    /// The version text as written ("0.17" or "0.17.1").
    text: []const u8,
    /// The `MAJOR.MINOR` family of the mention.
    family: Family,
    /// The patch component, when the mention carries one.
    patch: ?u32,
    /// True when the mention lives on a line that documents the historical
    /// `docs/investigation-2.md` reference — the only allowed exception.
    historical: bool,
};

/// A numeric version token found in a document.
const VersionToken = struct {
    text: []const u8,
    /// Number of dot-separated components (1..3).
    components: u8,
};

/// Skips the separators that may sit between "Zig" and its version.
fn skipToVersion(text: []const u8) []const u8 {
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        const c = text[i];
        const is_separator = switch (c) {
            ' ', '\t', '-', ':', '*', '`' => true,
            else => false,
        };
        if (!is_separator) break;
    }
    return text[i..];
}

/// Scans a numeric version token (`MAJOR`, `MAJOR.MINOR` or `MAJOR.MINOR.PATCH`)
/// at the start of `text`.
fn scanVersionToken(text: []const u8) ?VersionToken {
    var i: usize = 0;
    var components: u8 = 0;
    while (components < 3) {
        const start = i;
        while (i < text.len and text[i] >= '0' and text[i] <= '9') : (i += 1) {}
        if (i == start) return null; // no digits at all
        components += 1;
        if (components == 3) break;
        if (i >= text.len or text[i] != '.') break;
        // A '.' only continues the token when a digit follows it.
        if (i + 1 >= text.len or text[i + 1] < '0' or text[i + 1] > '9') break;
        i += 1;
    }
    return .{ .text = text[0..i], .components = components };
}

/// The `index`-th dot-separated component of a version token.
fn component(text: []const u8, index: usize) []const u8 {
    var it = std.mem.splitScalar(u8, text, '.');
    var i: usize = 0;
    while (it.next()) |part| : (i += 1) {
        if (i == index) return part;
    }
    return "";
}

/// Finds every "Zig <version>" mention in `content` and writes them to `out`.
fn findZigMentions(
    out: *[max_mentions]VersionMention,
    content: []const u8,
) GuardError!usize {
    var count: usize = 0;
    var line_no: usize = 0;
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        line_no += 1;
        const historical = std.mem.find(u8, line, historical_doc) != null;
        var from: usize = 0;
        while (std.mem.findPos(u8, line, from, "Zig")) |idx| {
            from = idx + "Zig".len;
            const token = scanVersionToken(skipToVersion(line[from..])) orelse continue;
            if (token.components < 2) continue; // not a version mention
            if (count >= max_mentions) return error.TooManyMentions;

            const major = try parseDecimal(component(token.text, 0));
            const minor = try parseDecimal(component(token.text, 1));
            var patch: ?u32 = null;
            if (token.components == 3) patch = try parseDecimal(component(token.text, 2));

            out[count] = .{
                .line = line_no,
                .text = token.text,
                .family = .{ .major = major, .minor = minor },
                .patch = patch,
                .historical = historical,
            };
            count += 1;
        }
    }
    return count;
}

test "S4: the README declares a single toolchain for the current code" {
    const agreed = try agreedPinVersion();
    const content = try readRepoFile(readme_path);
    defer testing.allocator.free(content);

    var mentions: [max_mentions]VersionMention = undefined;
    const total = try findZigMentions(&mentions, content);
    // The README must declare a toolchain at all.
    try testing.expect(total > 0);

    var exact: usize = 0;
    for (mentions[0..total]) |mention| {
        if (mention.historical) continue;
        if (!mention.family.eql(agreed.family())) {
            std.debug.print(
                "\n[S4] {s}:{d} declares Zig {s}, but the pinned toolchain is {d}.{d}.{d}\n",
                .{
                    readme_path,
                    mention.line,
                    mention.text,
                    agreed.major,
                    agreed.minor,
                    agreed.patch,
                },
            );
            return error.ToolchainMismatch;
        }
        if (mention.patch) |patch| {
            if (patch != agreed.patch) {
                std.debug.print(
                    "\n[S4] {s}:{d} declares Zig {s}, but the pinned toolchain is {d}.{d}.{d}\n",
                    .{
                        readme_path,
                        mention.line,
                        mention.text,
                        agreed.major,
                        agreed.minor,
                        agreed.patch,
                    },
                );
                return error.ToolchainMismatch;
            }
            exact += 1;
        }
    }

    // The README must name the exact pinned version somewhere (badge or the
    // "exact toolchain pinned" requirement), not only the minor line.
    if (exact == 0) {
        std.debug.print(
            "\n[S4] {s} never names the exact pinned toolchain {d}.{d}.{d}\n",
            .{ readme_path, agreed.major, agreed.minor, agreed.patch },
        );
        return error.ToolchainMismatch;
    }
}

test "S4: the README keeps its historical toolchain references scoped to docs/investigation-2.md" {
    const agreed = try agreedPinVersion();
    const content = try readRepoFile(readme_path);
    defer testing.allocator.free(content);

    // The historical document must still be referenced — otherwise the only
    // allowed exception would have no anchor left.
    try testing.expect(std.mem.find(u8, content, historical_doc) != null);

    var mentions: [max_mentions]VersionMention = undefined;
    const total = try findZigMentions(&mentions, content);
    for (mentions[0..total]) |mention| {
        if (mention.family.eql(agreed.family())) continue;
        if (mention.historical) continue;
        std.debug.print(
            "\n[S4] {s}:{d} declares the foreign toolchain '{s}' outside the historical {s} reference\n",
            .{ readme_path, mention.line, mention.text, historical_doc },
        );
        return error.ToolchainMismatch;
    }
}

test "S4: the README no longer claims the current code is written in Zig 0.16" {
    const content = try readRepoFile(readme_path);
    defer testing.allocator.free(content);

    // The three pre-bump claims about the *current* code. The historical
    // references to docs/investigation-2.md are allowed to stay (spec L7).
    const stale_claims = [_][]const u8{
        "written in **Zig 0.16**",
        "Zig 0.16 + stdlib only",
        "(Zig 0.16 std.Build)",
    };
    for (stale_claims) |claim| {
        if (std.mem.find(u8, content, claim) == null) continue;
        std.debug.print(
            "\n[S4] {s} still claims '{s}' about the current code\n",
            .{ readme_path, claim },
        );
        return error.ToolchainMismatch;
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// S5 — the local CI compares the image's Zig against the pin
// ─────────────────────────────────────────────────────────────────────────────

/// The local CI runner (owns the S5 fix).
const local_ci_path = "tools/local-ci.sh";

/// A line of `tools/local-ci.sh` that probes the CI image for its Zig version.
const ImageProbe = struct {
    /// 1-based line number of the probe.
    line: usize,
    /// The variable that holds the probed version.
    var_name: []const u8,
};

/// Extracts the name of the variable an assignment captures, e.g.
/// `IMAGE_ZIG_VERSION="$(podman run ...)"` yields `IMAGE_ZIG_VERSION`.
fn assignedVarName(line: []const u8) ?[]const u8 {
    const marker = "=\"$(";
    const idx = std.mem.find(u8, line, marker) orelse return null;
    var start = idx;
    while (start > 0 and isWordChar(line[start - 1])) start -= 1;
    if (start == idx) return null; // no identifier before the assignment
    return line[start..idx];
}

/// Finds the line where the local CI captures the CI image's Zig version.
fn findImageProbe(content: []const u8) ?ImageProbe {
    var line_no: usize = 0;
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        line_no += 1;
        if (std.mem.find(u8, line, "podman run") == null) continue;
        if (std.mem.find(u8, line, "zig version") == null) continue;
        const var_name = assignedVarName(line) orelse continue;
        return .{ .line = line_no, .var_name = var_name };
    }
    return null;
}

test "S5: tools/local-ci.sh compares the CI image's Zig version against the pinned one" {
    const content = try readRepoFile(local_ci_path);
    defer testing.allocator.free(content);

    // Comments are masked out: the comparison must exist in code, not in
    // prose.
    const masked = try commentMask(testing.allocator, content, .hash);
    defer testing.allocator.free(masked);

    const probe = findImageProbe(masked) orelse {
        std.debug.print(
            "\n[S5] {s} never probes the CI image for its 'zig version'\n",
            .{local_ci_path},
        );
        return error.StaleImageGuardMissing;
    };

    var compared_line: usize = 0;
    var line_no: usize = 0;
    var lines = std.mem.splitScalar(u8, masked, '\n');
    while (lines.next()) |line| {
        line_no += 1;
        if (std.mem.find(u8, line, "!=") == null) continue;
        if (std.mem.find(u8, line, "ZIG_VERSION") == null) continue;
        if (std.mem.find(u8, line, probe.var_name) == null) continue;
        compared_line = line_no;
        break;
    }
    if (compared_line == 0) {
        std.debug.print(
            "\n[S5] {s} never compares the image's Zig version ({s}, probed at line {d}) against ZIG_VERSION\n",
            .{ local_ci_path, probe.var_name, probe.line },
        );
        return error.StaleImageGuardMissing;
    }
}

test "S5: tools/local-ci.sh reports the mismatch and re-bakes the CI image" {
    const content = try readRepoFile(local_ci_path);
    defer testing.allocator.free(content);

    const masked = try commentMask(testing.allocator, content, .hash);
    defer testing.allocator.free(masked);

    var reported_line: usize = 0;
    var line_no: usize = 0;
    var lines = std.mem.splitScalar(u8, masked, '\n');
    while (lines.next()) |line| {
        line_no += 1;
        if (std.mem.find(u8, line, "re-baking") == null) continue;
        if (std.mem.find(u8, line, "expected") == null) continue;
        if (std.mem.find(u8, line, "ZIG_VERSION") == null) continue;
        reported_line = line_no;
        break;
    }
    if (reported_line == 0) {
        std.debug.print(
            "\n[S5] {s} has no re-bake message naming the expected Zig version\n",
            .{local_ci_path},
        );
        return error.StaleImageGuardMissing;
    }
}
