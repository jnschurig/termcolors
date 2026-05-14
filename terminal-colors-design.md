# Terminal Color Probe — Design Document

**Status:** Draft **Last updated:** 2026-05-14 **Binary name:** `termcolors`

## Overview

A small command-line binary that queries a running terminal emulator for its current color palette and emits the result in a machine-readable format. The "primary theme colors" — the 16 ANSI base slots plus foreground, background, cursor, and selection — are reported in a single notation chosen by the caller (hex, rgb, hsl, or oklch). The tool exists to be piped: shell scripts, theme exporters, status bar generators, and other programs should be able to invoke it and get a stable, predictable output without having to know which terminal they're running inside.

## Goals

- Report the current runtime colors of the active terminal, including any user overrides.
- Work without knowing which terminal emulator is in use.
- Produce stable, well-specified output suitable for piping into other tools.
- Single static binary, no runtime dependencies, fast (tens of milliseconds).
- One notation per invocation; consumers pick the representation they want.

## Non-goals

- Parsing terminal config files (iTerm2 plists, Alacritty TOML, etc.). The runtime query is the source of truth; reading config files is a separate problem with N implementations.
- Generating, manipulating, or harmonizing themes. This tool reads; it doesn't compose.
- Detecting terminal capabilities beyond what's needed to query colors.
- A library API. The contract is the CLI and its output schema; calling code embeds via subprocess.

## Color acquisition

The tool uses OSC (Operating System Command) escape sequences to query the terminal at runtime. The relevant sequences:

- `ESC ] 4 ; n ; ? BEL` — palette index `n`, where `n ∈ [0, 255]`. Indices 0–15 are the 16 ANSI slots; 16–255 are the 256-color extension.
- `ESC ] 10 ; ? BEL` — foreground
- `ESC ] 11 ; ? BEL` — background
- `ESC ] 12 ; ? BEL` — cursor
- `ESC ] 17 ; ? BEL` — selection background
- `ESC ] 19 ; ? BEL` — selection foreground

The terminal replies with `ESC ] <type> ; rgb:RRRR/GGGG/BBBB BEL` (or `ESC \` instead of `BEL`). Channel widths vary by terminal — 2-digit and 4-digit forms are both common, and some terminals emit an `rgba:` form with an alpha channel. The parser must accept all of these permissively.

Queries are batched: all sequences are written at once, then responses are read with a single bounded loop, matched to their originating query by OSC type. This collapses \~20 sequential round-trips into one.

The TTY is accessed via `/dev/tty` directly, never stdin or stdout — the tool must work correctly when piped.

## Architecture

The codebase is divided into modules with sharp seams:

- **terminal** — owns the TTY lifecycle. Opens `/dev/tty`, manages raw mode, restores state on every exit path including panics and signals (SIGINT/SIGTERM/SIGTSTP).
- **query** — knows the OSC sequence syntax. Writes a batch of queries, reads bytes until terminator, dispatches each reply to the parser.
- **parser** — pure functions over byte slices. Handles `rgb:` and `rgba:` forms with 2-digit and 4-digit channels, plus both terminator variants.
- **palette** — domain model. `Color` (rgb triple) plus a `Palette` record with the indexed array, the special slots, and optional alias map.
- **convert** — color-space transforms. `rgb → hex`, `rgb → hsl`, `rgb → oklch`. Pure functions.
- **output** — serializers, one per format.
- **multiplexer** — detects `TMUX`/`STY` and wraps queries in passthrough sequences. Pure dispatch; the terminal module doesn't know about it.
- **cli** — argument parsing, top-level orchestration.

Flow: cli → multiplexer (wrap if needed) → terminal (open, raw) → query (batch send) → parser (decode replies) → convert (transform to chosen notation) → output (serialize) → terminal (restore) → stdout.

## CLI surface

| Flag | Type | Default | Meaning |
| :---- | :---- | :---- | :---- |
| `--format` | enum | `json` | Output encoding: `json`, `toml`, `env`, `flat` |
| `--color` | enum | `hex` | Notation: `hex`, `rgb`, `hsl`, `oklch` |
| `--only` | list | (all) | Subset of slots: `fg`, `bg`, `cursor`, `selection_bg`, `selection_fg`, or palette indices like `0,7,15` |
| `--include-aliases` | bool | `false` | Add an alias map (`black`→0, `red`→1, …) pointing into palette indices |
| `--include-256` | bool | `false` | Extend palette array from 16 to 256 entries |
| `--timeout-ms` | int | `200` | Per-query timeout in ms; clamped to `[25, 5000]`. Queries that don't reply in time produce `null` |
| `--no-multiplexer-wrap` | bool | `false` | Disable tmux passthrough wrapping even if detected |

`--only` filters output, not querying. The probe always queries the full palette and all special slots; `--only` controls what reaches stdout. Filtered-out palette indices appear as `null` in the array so positional indexing remains stable; filtered-out special slots are omitted from the `special` object.

The default `--timeout-ms` of 200 covers local terminals and most LAN/SSH cases. Bump it for slow links; the bounds (25 ms low, 5000 ms high) exist to keep callers from accidentally disabling the timeout or setting it below the practical response floor.

## Output contract

### `--format json` (canonical)

```json
{
  "palette": [
    "#1d1f21",
    "#cc6666",
    "#b5bd68",
    "#f0c674",
    "#81a2be",
    "#b294bb",
    "#8abeb7",
    "#c5c8c6",
    "#969896",
    "#cc6666",
    "#b5bd68",
    "#f0c674",
    "#81a2be",
    "#b294bb",
    "#8abeb7",
    "#ffffff"
  ],
  "special": {
    "foreground": "#c5c8c6",
    "background": "#1d1f21",
    "cursor": null,
    "selection_background": "#373b41",
    "selection_foreground": "#c5c8c6"
  },
  "meta": {
    "schema_version": 1,
    "notation": "hex",
    "queried_at": "2026-05-14T12:34:56Z",
    "unsupported": ["cursor"],
    "multiplexer": null
  }
}
```

`palette` is an array of length 16 (or 256 with `--include-256`). Position is the identifier — index 0 through index N−1, in ANSI order. `null` entries indicate the terminal did not respond within the timeout, or that the slot was excluded by `--only`.

`special` is a map of role names. Entries the terminal did not respond to appear as explicit `null`, not as missing keys, so consumers see a stable schema.

`meta` records the run context. `schema_version` is an integer that increments only on breaking changes to the contract — additive changes (new optional fields, new notations, new format values) don't bump it, so consumers pinning to `schema_version: 1` keep working as the tool evolves. The remaining fields describe this particular invocation: notation chosen, when the query ran, which slots failed to respond, and any multiplexer wrapping that was applied.

With `--include-aliases`, an additional top-level `aliases` object is emitted:

```json
"aliases": {
  "black": 0, "red": 1, "green": 2, "yellow": 3,
  "blue": 4, "magenta": 5, "cyan": 6, "white": 7,
  "bright_black": 8, "bright_red": 9, "bright_green": 10, "bright_yellow": 11,
  "bright_blue": 12, "bright_magenta": 13, "bright_cyan": 14, "bright_white": 15
}
```

Aliases are integers pointing into the palette array, never duplicated color values. This makes it visibly clear that the names are a convention (the vt100 tradition) rather than ground truth about the theme — slot 1 is "what this theme uses for ANSI red," whatever color that actually is.

### `--format toml`

Same shape as JSON, transcribed to TOML:

```
[meta]
notation = "hex"
queried_at = "2026-05-14T12:34:56Z"
unsupported = ["cursor"]

palette = ["#1d1f21", "#cc6666", "#b5bd68", "..."]

[special]
foreground = "#c5c8c6"
background = "#1d1f21"
```

### `--format env`

Shell-sourceable. Indexed slots use the `ANSI_` prefix to avoid collisions with common environment variables:

```shell
ANSI_0=#1d1f21
ANSI_1=#cc6666
# ...
ANSI_15=#ffffff
ANSI_FG=#c5c8c6
ANSI_BG=#1d1f21
ANSI_CURSOR=
ANSI_SELECTION_BG=#373b41
ANSI_SELECTION_FG=#c5c8c6
```

An empty value indicates `null` (no terminal response). With `--include-aliases`, additional `ANSI_BLACK=#1d1f21`, `ANSI_RED=#cc6666`, etc. are emitted alongside the indexed keys.

### `--format flat`

One color per line: palette first in index order, then special slots in fixed order (foreground, background, cursor, selection\_background, selection\_foreground). Missing/unsupported entries emit an empty line so position remains meaningful.

```
#1d1f21
#cc6666
#b5bd68
...
#ffffff
#c5c8c6
#1d1f21

#373b41
#c5c8c6
```

## Notation forms

Per `--color`, each color value is one of:

| Notation | Example |
| :---- | :---- |
| `hex` | `#1d1f21` |
| `rgb` | `rgb(29 31 33)` |
| `hsl` | `hsl(220 6% 12%)` |
| `oklch` | `oklch(22% 0.005 250)` |

All forms follow modern CSS Color 4 syntax with space-separated components. Consumers parsing JSON receive these as strings; they can paste directly into stylesheets, or split on whitespace and parentheses for individual components.

`oklch` is included because it's perceptually uniform — the right space for consumers doing color math (interpolating between palette entries, generating shaded variants, picking contrasting text colors).

## Failure modes

- **No TTY available** (CI, daemon context). The tool fails fast with exit code 2 and a stderr message. It does not hang waiting for the timeout.
- **Terminal doesn't support a query.** The slot's value is `null` and the slot is listed in `meta.unsupported`. The overall invocation succeeds with exit code 0\.
- **Total timeout** (terminal supports nothing). All slots `null`; exit code 0 but `meta.unsupported` enumerates every queried slot. Calling code decides whether to treat this as failure.
- **Inside a multiplexer with passthrough disabled.** Detected by recognising the env vars (`TMUX`, `STY`) and getting no response to any query; exit code 3 with a stderr hint mentioning `allow-passthrough`.
- **Signal during raw mode.** Handler restores terminal state and exits with the conventional `128 + signo`.

Exit codes:

- `0` — success (including partial success with `null`s)
- `1` — bad CLI arguments
- `2` — no TTY available
- `3` — multiplexer passthrough required but disabled
- `128 + n` — terminated by signal `n`

## Distribution

- Single static binary; no shared-library dependencies.
- Targets: Linux (x86\_64, aarch64), macOS (x86\_64, aarch64), BSDs. Windows is out of scope for v1 — its terminal color story is different enough to warrant separate design.
- Cold-start to exit under 50ms on a local terminal with all queries succeeding.
- Memory footprint trivial; the parsed palette fits in well under 1KB.

## Future considerations

These are deferred to keep v1 scope tight. None require breaking the schema to add later — `schema_version` stays at 1 as they land:

- **`meta.app_version`.** An optional field reporting the binary's release version. Useful for consumer-side debugging against specific releases, and cheap to add once the project has a release process.
- **Additional special slots.** Bold color (some terminals distinguish bold from bright), mouse cursor foreground, link/underline color. Out of v1, revisit if a real consumer needs them.
- **256-color aliases.** Indices 16–255 form a structured 6×6×6 cube plus a grayscale ramp; they're canonically referred to by index. We could expose names if a consumer asks, but the index identifier stays primary.
- **Windows support.** Windows Terminal speaks OSC and could be supported; the Windows console host has a different model. Better as a separate design pass than retrofitted into v1.
