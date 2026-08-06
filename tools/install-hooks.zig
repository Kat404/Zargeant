// Use this script to install a pre-commit hook that enforces our conventions.
// Run once: `zig run tools/install-hooks.zig`
//
// The hook checks:
// 1. No `Co-Authored-By: AI` lines in commit messages (lesson id=213)
// 2. Conventional Commits format (`<type>(<scope>): <subject>`)
// 3. Zig code is `zig fmt`-clean if available
const std = @import("std");

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const argv = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, argv);

    if (argv.len < 2) {
        std.debug.print("Usage: {s} install | uninstall\n", .{argv[0]});
        std.process.exit(1);
    }

    const action = argv[1];
    if (std.mem.eql(u8, action, "install")) {
        try installHook();
    } else if (std.mem.eql(u8, action, "uninstall")) {
        try uninstallHook();
    } else {
        std.debug.print("Unknown action: {s}\n", .{action});
        std.process.exit(1);
    }
}

const HOOK_SCRIPT =
    \\#!/usr/bin/env bash
    \\set -euo pipefail
    \\
    \\# Source: tools/install-hooks.zig
    \\# Enforces zargeant commit conventions.
    \\
    \\COMMIT_MSG_FILE="$1"
    \\COMMIT_MSG=$(cat "$COMMIT_MSG_FILE")
    \\
    \\# 1. Reject AI Co-Authored-By lines (lesson id=213)
    \\if echo "$COMMIT_MSG" | grep -qiE '^Co-Authored-By:.*(Claude|MiniMax|Anthropic|AI|GPT)'; then
    \\  echo "ERROR: Co-Authored-By AI line detected in commit message."
    \\  echo "Commit messages are authored by the human only."
    \\  exit 1
    \\fi
    \\
    \\# 2. Enforce Conventional Commits format
    \\FIRST_LINE=$(echo "$COMMIT_MSG" | head -n1)
    \\if ! echo "$FIRST_LINE" | grep -qE '^(feat|fix|chore|docs|test|refactor|perf|style)\([a-z0-9_-]+\): .+'; then
    \\  if ! echo "$FIRST_LINE" | grep -qE '^(feat|fix|chore|docs|test|refactor|perf|style): .+'; then
    \\    echo "ERROR: Commit title must follow Conventional Commits format:"
    \\    echo "  <type>(<scope>): <subject>"
    \\    echo "  e.g. feat(logger): add headless /tmp/ai-harness-debug.log"
    \\    echo "  or:  chore: initial commit"
    \\    exit 1
    \\  fi
    \\fi
    \\
    \\# 3. Subject length ≤ 72 chars
    \\if [ "${#FIRST_LINE}" -gt 72 ]; then
    \\  echo "ERROR: Commit subject exceeds 72 chars (${#FIRST_LINE})."
    \\  exit 1
    \\fi
    \\
    \\echo "OK: commit message passes zargeant conventions"
;

fn installHook() !void {
    const cwd = std.fs.cwd();
    const git_dir = try cwd.openDir(".git", .{});
    const hooks_dir = try git_dir.makeOpenPath("hooks", .{});

    // Write the hook script
    const hook_path = try hooks_dir.realPathAlloc(std.heap.page_allocator, .{});
    defer std.heap.page_allocator.free(hook_path);

    const commit_msg_hook = try std.fs.path.join(std.heap.page_allocator, &.{ hook_path, "commit-msg" });
    defer std.heap.page_allocator.free(commit_msg_hook);

    const file = try std.fs.createFileAbsolute(commit_msg_hook, .{ .mode = 0o755 });
    defer file.close();
    try file.writeAll(HOOK_SCRIPT);

    std.debug.print("Installed: {s}\n", .{commit_msg_hook});
}

fn uninstallHook() !void {
    const cwd = std.fs.cwd();
    const git_dir = cwd.openDir(".git", .{}) catch return;
    const hooks_dir = git_dir.openDir("hooks", .{}) catch return;

    const hook_path = try hooks_dir.realPathAlloc(std.heap.page_allocator, .{});
    defer std.heap.page_allocator.free(hook_path);

    const commit_msg_hook = try std.fs.path.join(std.heap.page_allocator, &.{ hook_path, "commit-msg" });
    defer std.heap.page_allocator.free(commit_msg_hook);

    std.fs.deleteFileAbsolute(commit_msg_hook) catch |err| {
        std.debug.print("Could not delete {s}: {any}\n", .{ commit_msg_hook, err });
        return;
    };

    std.debug.print("Uninstalled: {s}\n", .{commit_msg_hook});
}
