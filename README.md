# termcolors

A small command-line tool that asks the running terminal emulator what its current colors are and prints them in a machine-readable format. Useful for shell scripts, theme exporters, status-bar generators, and anything else that needs to match the active terminal palette without parsing config files.

## What it reports

The 16 ANSI palette slots plus foreground, background, cursor, and selection foreground/background. Optionally, the full 256-color extension and well-known aliases (`red`, `bright_red`, …).

Colors are queried at runtime via OSC escape sequences (`ESC ] 4 ; n ; ? BEL`, `ESC ] 10/11/12/17/19 ; ? BEL`), so user overrides and live theme changes are reflected. The TTY is accessed through `/dev/tty` directly, so the tool works correctly when piped.

## Install

Requires Zig `>= 0.15.0`.

```sh
zig build -Doptimize=ReleaseFast
./zig-out/bin/termcolors
```

Cross-compile static release binaries for all supported targets (linux x86_64/aarch64 musl, macOS x86_64/aarch64):

```sh
zig build release
# binaries land in zig-out/dist/<triple>/termcolors
```

## Usage

```
termcolors [--format=json|env|flat] [--color=hex|rgb|hsl|oklch]
           [--only=...] [--timeout-ms=N] [--include-aliases]
           [--include-256] [--no-multiplexer-wrap]
```

Default output is JSON with hex colors. Examples:

```sh
termcolors                            # JSON, hex
termcolors --format=env --color=rgb   # shell-eval'able: COLOR_0=...
termcolors --color=oklch              # perceptual color space
termcolors --include-256              # all 256 palette slots
```

Inside `tmux` or `screen`, queries are automatically wrapped in passthrough sequences. For tmux you must also enable passthrough on the server:

```sh
tmux set -g allow-passthrough on
```

## Exit codes

| Code | Meaning |
|------|---------|
| 0    | success |
| 1    | argument error |
| 2    | no controlling tty (`/dev/tty` unavailable) |
| 3    | running inside a multiplexer with no passthrough |

## Development

```sh
zig build        # debug build
zig build test   # run unit tests
zig fmt src/     # format
```

`pre-commit` runs `zig fmt --check`; `zig build` and `zig build test` run on pre-push.

See [`terminal-colors-design.md`](./terminal-colors-design.md) for the full design — color acquisition protocol, output schema, module layout, and the contract for callers.
