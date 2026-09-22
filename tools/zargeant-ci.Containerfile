# tools/zargeant-ci.Containerfile — Alpine-based CI image (lightweight).
#
# Migrated from ubuntu:24.04 → alpine:3.20 to reduce image footprint
# (ubuntu ~77 MB base + Zig ~210 MB ≈ 540 MB; alpine ~7 MB + Zig ≈ 240 MB).
#
# Zig 0.16.0 host tarball (zig-x86_64-linux) is glibc-linked. Alpine ships
# musl, so we install `gcompat` as a thin glibc compatibility layer that
# covers the few libc symbols Zig dynamically pulls in at startup. This is
# the official Alpine-recommended approach for running glibc binaries
# (https://wiki.alpinelinux.org/wiki/Running_glibc_programs).
#
# Build context = repo root (so zig build test can find src/, build.zig, etc).
# Override ZIG_VERSION with --build-arg if needed.

FROM docker.io/library/alpine:3.20
ENV DEBIAN_FRONTEND=noninteractive

# Runtime deps:
#   ca-certificates — TLS for ziglang.org download
#   curl            — Zig download
#   xz              — extract .tar.xz tarball
#   git             — Co-Authored-By guard in CI workflow
#   bash            — justfile + this Containerfile use bash syntax
#   gcompat         — glibc compat layer for the Zig compiler binary
RUN apk add --no-cache \
      ca-certificates curl xz git bash gcompat \
 && update-ca-certificates

ARG ZIG_VERSION=0.16.0
RUN curl -fsSLO "https://ziglang.org/download/${ZIG_VERSION}/zig-x86_64-linux-${ZIG_VERSION}.tar.xz" \
 && tar -xf "zig-x86_64-linux-${ZIG_VERSION}.tar.xz" \
 && mv "zig-x86_64-linux-${ZIG_VERSION}" /opt/zig \
 && ln -sf /opt/zig/zig /usr/local/bin/zig \
 && rm -f "zig-x86_64-linux-${ZIG_VERSION}.tar.xz"

ENV PATH="/opt/zig:${PATH}"
WORKDIR /workspace
