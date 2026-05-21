# termcolors

A small command-line tool that asks the running terminal emulator what its current colors are and prints them in a machine-readable format. Useful for shell scripts, theme exporters, status-bar generators, and anything else that needs to match the active terminal palette without parsing config files.

## What it reports

The 16 ANSI palette slots plus foreground, background, cursor, and selection foreground/background. Optionally, the full 256-color extension and well-known aliases (`red`, `bright_red`, …).

Colors are queried at runtime via OSC escape sequences (`ESC ] 4 ; n ; ? BEL`, `ESC ] 10/11/12/17/19 ; ? BEL`), so user overrides and live theme changes are reflected. The TTY is accessed through `/dev/tty` directly, so the tool works correctly when piped.

## Install

### Homebrew (macOS, Linux)

```sh
brew install jnschurig/termcolors/termcolors
```

The tap [`jnschurig/homebrew-termcolors`](https://github.com/jnschurig/homebrew-termcolors) ships prebuilt binaries for Apple Silicon + Intel macOS and aarch64 + x86_64 Linux (musl, statically linked). The formula is updated automatically on every release.

### From source

Zig toolchain version is pinned via `mise.toml`.

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
           [--source=auto|osc|<emulator>|<abs-path>]
           [--osc-min-palette=N]
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

## Sources

The OSC probe needs a live terminal. When `termcolors` runs in a headless context — nvim's `:terminal`, a hyprland keybind script, CI, an embedded service — there's no TTY to query, and even when there is one (e.g. nvim's terminal-emulator buffer), the host may not answer OSC.

`--source` selects how colors are acquired:

| Value | Behavior |
|------|----------|
| `auto` (default) | Run OSC first; if the result is insufficient, fall back to the configured emulator (see below). Never hard-fails — returns a null-filled palette as a last resort. |
| `osc` | OSC only. Hard-fails with exit 2 if no TTY. |
| `<emulator-name>` | Skip OSC; invoke that emulator's CLI directly. This cycle: `ghostty`. |
| `<absolute-path>` | Skip OSC; invoke this exact binary. The basename must match a compiled-in source (e.g. `/opt/homebrew/bin/ghostty`). |

Example: produce the active Ghostty palette from inside nvim's `:terminal`:

```sh
termcolors --source ghostty
```

### Picking a fallback for `auto`

In `auto` mode, the fallback emulator (used when OSC fails or returns too few colors) comes from one of these, in priority order:

1. `$TERMCOLORS_TERMINAL` environment variable. Value: an emulator name (e.g. `ghostty`) or an absolute path. Mode keywords (`auto`, `osc`) are not valid here.
2. Config file key `termcolors_source` (see next section).

If neither is set, `auto` runs OSC only — and silently degrades to a null-filled palette if even OSC produces nothing. Callers can branch on the data (`palette[0] == null`?) rather than on exit codes.

The `--osc-min-palette N` flag (default 8, range 1–16) controls how many of the 16 base palette slots OSC must return to count as "sufficient" before the fallback is skipped. Lower it for more lenient OSC results; raise it to force fallback more aggressively.

### Config file

Optional. Resolved from `$XDG_CONFIG_HOME/termcolors/config` (when XDG is set) or `~/.config/termcolors/config`. Plain text, `key = value`, one pair per line. `#` starts a comment.

Recognized keys:

| Key | Meaning |
|-----|---------|
| `termcolors_source` | Fallback emulator for `--source auto`. Value: a known source name (`ghostty`) or an absolute path whose basename matches a known source. |

Minimal example:

```
# ~/.config/termcolors/config
termcolors_source = ghostty
```

### Output metadata

`meta.source` (always present in every format) records which source actually produced the colors — `"osc"` or an emulator name. Treat it as an open string set: future versions will add more values. Don't strict-enum-check it.

`meta.theme` is the theme name reported by emulator sources that expose one (Ghostty); `null` for OSC.

## Exit codes

| Code | Meaning |
|------|---------|
| 0    | success (including `--source auto` falling back to a null-filled palette) |
| 1    | argument error or config-file error |
| 2    | `--source osc` with no controlling tty |
| 3    | running inside a multiplexer with no passthrough (when no fallback succeeded) |
| 4    | emulator source failed: binary missing, subprocess error, or malformed output |

## Development

```sh
zig build                   # debug build
zig build test              # run unit tests
zig build test-integration  # PTY-based end-to-end tests (spawns the real binary)
zig fmt src/                # format
```

`pre-commit` runs `zig fmt --check`; `zig build` and `zig build test` run on pre-push.

Integration tests live in [`tests/integration.zig`](./tests/integration.zig). They `forkpty` a child process, exec the built `termcolors` binary, and play the role of a terminal emulator — reading the OSC queries the binary writes to `/dev/tty` and responding with a fixture palette. This exercises the raw-mode TTY lifecycle, batched query write, deadline-bounded read loop, and reply parser end-to-end without needing a real terminal emulator on the host. Real-emulator quirks (Kitty/iTerm2/Ghostty divergences) are out of scope for these tests and stay in the manual pre-release smoke check.

### CI

GitHub Actions (`.github/workflows/ci.yml`) runs `zig fmt --check`, `zig build`, `zig build test`, and `zig build test-integration` on `ubuntu-latest` and `macos-latest` for every push and PR. Pushing a `v*` tag additionally runs the `release` job, which cross-compiles all four target binaries and publishes them as a GitHub Release. The release job can also be invoked manually from the Actions tab (workflow dispatch) for a dry-run that uploads the tarballs as a workflow artifact without publishing a Release.

See [`terminal-colors-design.md`](./terminal-colors-design.md) for the full design — color acquisition protocol, output schema, module layout, and the contract for callers.
