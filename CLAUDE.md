# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

`termcolors` — a small Zig CLI that queries the active terminal emulator for its current color palette via OSC escape sequences and emits the result in a machine-readable format (json/env/flat, in hex/rgb/hsl/oklch). Requires Zig >= 0.17.1. No dependencies.

See `terminal-colors-design.md` for the authoritative design (color acquisition protocol, output schema, error/exit-code contract).

## Commands

- `zig build` — build debug binary into `zig-out/bin/termcolors`.
- `zig build run -- <args>` — build and run (pass CLI args after `--`).
- `zig build test` — run unit tests (entry point is `test {}` in `src/main.zig`, which `refAllDecls` all modules; tests live alongside source).
- `zig build test-integration` — run PTY-backed integration tests in `tests/integration.zig`. Forks the real binary under `forkpty`, replies to its OSC queries with a fixture palette, asserts on stdout + exit code. Covers the TTY/query/read pipeline that pure-module tests can't reach.
- `zig build release` — cross-compile static release binaries for the four supported targets (linux x86_64/aarch64 musl, macOS x86_64/aarch64) into `zig-out/dist/<triple>/`.
- `zig fmt src/ tests/` — format. `zig fmt --check` runs in pre-commit; `zig build` and `zig build test` run on pre-push.

To run a single unit test, use `zig test src/<file>.zig` (or add a temporary filter); there is no per-test `build.zig` step.

CI (`.github/workflows/ci.yml`): matrix over `ubuntu-latest` + `macos-latest` runs fmt-check, build, unit tests, and integration tests on every push/PR. Tagged pushes (`v*`) build cross-compiled release binaries and publish a GitHub Release; workflow_dispatch runs the release job as a dry-run that uploads artifacts without publishing.

## Architecture

The pipeline is a one-shot probe with sharp module seams. Flow:

`cli` → `multiplexer` (wrap if inside tmux/screen) → `terminal` (open `/dev/tty`, enter raw mode) → `query` (batch-write OSC queries, read replies with one bounded loop) → `parser` (decode `rgb:`/`rgba:` replies, both terminator forms) → `convert` (rgb → chosen notation) → `output` (serialize) → restore TTY → stdout.

That flow is the OSC source (`src/sources/osc.zig`). `--source <emulator>` skips it and reads colors without a TTY from an emulator source: `src/sources/ghostty.zig` (runs `ghostty +show-config`) or `src/sources/rex.zig` (macOS prefs + the Rex app's bundled `themes.json`; pure `parseThemes`/`resolveScheme`, with all platform-specific lookup in `locate`). `main.zig` dispatches on source name in `acquireEmulator`; `--source auto` tries OSC first, then the configured fallback emulator.

Key invariants to preserve when editing:

- **TTY isolation:** all terminal I/O goes through `/dev/tty` (never stdin/stdout) so the tool works under pipes. `terminal.zig` owns raw-mode lifecycle and must restore on every exit path including panics/signals.
- **Batched queries:** `query.writeQueries` sends all OSC sequences before reading any reply. Don't reintroduce per-request round-trips — the design budget is tens of milliseconds total.
- **Permissive parser:** terminals vary in channel width (2- vs 4-digit), include/omit alpha, and terminate with `BEL` or `ESC \`. The parser must accept all of these.
- **Multiplexer passthrough:** when `TMUX`/`STY` is set, queries are wrapped so the host terminal sees them. If every reply is missing inside a multiplexer, exit 3 with the tmux passthrough hint (see `main.zig`).
- **Module purity:** `parser`, `convert`, and `multiplexer` are pure over their inputs; don't pull TTY or allocator state into them.

Exit codes: `0` success, `1` argument error, `2` no controlling tty, `3` multiplexer with no passthrough, `4` emulator source failed.
