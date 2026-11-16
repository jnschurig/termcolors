//! Rex source: resolves the active theme ID from Rex's preferences and looks
//! it up in the `themes.json` shipped inside the Rex app bundle, then in the
//! custom (imported / user-made) themes Rex keeps in its preferences. No TTY
//! required. Relies on undocumented Rex internals (prefs keys, bundle layout,
//! `themes.json` and custom-theme schemas).

const std = @import("std");
const builtin = @import("builtin");
const palette_mod = @import("../palette.zig");
const cli = @import("../cli.zig");

pub const AcquireError = error{
    UnsupportedPlatform,
    AppNotFound,
    ThemeIdMissing,
    ThemeNotFound,
    MalformedThemes,
    MalformedCustomThemes,
    OutOfMemory,
};

pub const Result = struct {
    palette: palette_mod.Palette,
    /// Theme display name (e.g. "Merino Dark"), or null when the entry has none.
    theme: ?[]u8,
    /// Allocator ownership: caller frees both via `deinit`.
    indexed_owner: []?palette_mod.Color,

    pub fn deinit(self: *Result, allocator: std.mem.Allocator) void {
        allocator.free(self.indexed_owner);
        if (self.theme) |t| allocator.free(t);
        self.* = undefined;
    }
};

pub const Scheme = enum { dark, light };

/// Pick the dark or light theme slot.
///
/// `rex_appearance` is Rex's own color-scheme override; when it names `dark`
/// or `light` (any case) it wins. Otherwise (auto, absent, unrecognized) the
/// system decides: `system_style` is macOS `AppleInterfaceStyle`, which is
/// `Dark` in dark mode and absent in light mode.
pub fn resolveScheme(rex_appearance: ?[]const u8, system_style: ?[]const u8) Scheme {
    if (rex_appearance) |a| {
        if (std.ascii.eqlIgnoreCase(a, "dark")) return .dark;
        if (std.ascii.eqlIgnoreCase(a, "light")) return .light;
    }
    if (system_style) |s| {
        if (std.ascii.eqlIgnoreCase(s, "dark")) return .dark;
    }
    return .light;
}

/// Detail for the most recent `acquire` failure: the prefs key, theme ID, or
/// file path involved. Empty when there is nothing useful to add.
pub var last_detail: [512]u8 = undefined;
pub var last_detail_len: usize = 0;

fn setDetail(comptime fmt: []const u8, args: anytype) void {
    const written = std.fmt.bufPrint(&last_detail, fmt, args) catch {
        last_detail_len = 0;
        return;
    };
    // Echoed to the user's terminal, and built from prefs values and paths.
    for (written) |*c| {
        if (std.ascii.isControl(c.*)) c.* = '?';
    }
    last_detail_len = written.len;
}

/// Read the active Rex theme without a TTY.
pub fn acquire(
    gpa: std.mem.Allocator,
    io: std.Io,
    opts: cli.Options,
    env_map: *const std.process.Environ.Map,
) AcquireError!Result {
    last_detail_len = 0;
    var loc = try locate(gpa, io, env_map);
    defer loc.deinit(gpa);

    // Built-in themes resolve from the bundle alone; the custom themes are
    // only fetched (one more subprocess) when that misses.
    const from_bundle = tryBundle(gpa, loc.themes_json, loc.theme_id, opts.include_256) catch |err| {
        if (err == AcquireError.MalformedThemes) setDetail("{s}", .{loc.themes_path orelse ""});
        return err;
    };
    if (from_bundle) |r| return r;

    const custom_json = try readCustomThemes(gpa, io);
    defer if (custom_json) |c| gpa.free(c);

    return resolveCustom(gpa, loc.themes_json != null, custom_json, loc.theme_id, opts.include_256) catch |err| {
        switch (err) {
            AcquireError.ThemeNotFound => setDetail("theme '{s}' not found in {s} or {s}", .{ loc.theme_id, loc.themes_path orelse "themes.json", CUSTOM_THEMES_KEY }),
            AcquireError.AppNotFound => setDetail("no readable themes.json in 'Rex Beta.app' or 'Rex.app' under /Applications or ~/Applications, and theme '{s}' is not in {s}", .{ loc.theme_id, CUSTOM_THEMES_KEY }),
            AcquireError.MalformedCustomThemes => setDetail("{s} in the {s} preferences (theme '{s}')", .{ CUSTOM_THEMES_KEY, PREFS_DOMAIN, loc.theme_id }),
            else => {},
        }
        return err;
    };
}

/// Bundle half of the lookup. Null means "not a built-in theme, try the
/// custom themes": either there is no bundle or the ID isn't in it. A
/// malformed bundle is an error, not a fall-through.
fn tryBundle(
    gpa: std.mem.Allocator,
    bundle_json: ?[]const u8,
    theme_id: []const u8,
    include_256: bool,
) AcquireError!?Result {
    const text = bundle_json orelse return null;
    return parseThemes(gpa, text, theme_id, include_256) catch |err| switch (err) {
        AcquireError.ThemeNotFound => null,
        else => err,
    };
}

/// Custom half of the lookup, reached only after `tryBundle` returned null.
/// An ID found nowhere is `ThemeNotFound` when a bundle was searched and
/// `AppNotFound` when there was no bundle to search.
fn resolveCustom(
    gpa: std.mem.Allocator,
    have_bundle: bool,
    custom_json: ?[]const u8,
    theme_id: []const u8,
    include_256: bool,
) AcquireError!Result {
    const not_found = if (have_bundle) AcquireError.ThemeNotFound else AcquireError.AppNotFound;
    const text = custom_json orelse return not_found;
    return parseCustomThemes(gpa, text, theme_id, include_256) catch |err| switch (err) {
        AcquireError.ThemeNotFound => not_found,
        else => err,
    };
}

/// The whole lookup over already-loaded inputs: built-in themes first, then
/// custom themes. `acquire` runs the same two halves with the custom-themes
/// fetch in between.
pub fn resolveTheme(
    gpa: std.mem.Allocator,
    bundle_json: ?[]const u8,
    custom_json: ?[]const u8,
    theme_id: []const u8,
    include_256: bool,
) AcquireError!Result {
    if (try tryBundle(gpa, bundle_json, theme_id, include_256)) |r| return r;
    return resolveCustom(gpa, bundle_json != null, custom_json, theme_id, include_256);
}

/// Everything that depends on where a given platform's Rex keeps its state.
const Located = struct {
    theme_id: []u8,
    /// Null when no Rex app bundle with a readable `themes.json` was found.
    themes_path: ?[]u8,
    themes_json: ?[]u8,

    fn deinit(self: *Located, gpa: std.mem.Allocator) void {
        gpa.free(self.theme_id);
        if (self.themes_path) |p| gpa.free(p);
        if (self.themes_json) |t| gpa.free(t);
        self.* = undefined;
    }
};

/// The only platform-specific piece: find the selected theme ID and the text
/// of `themes.json`. Supporting another platform means adding a branch here.
fn locate(
    gpa: std.mem.Allocator,
    io: std.Io,
    env_map: *const std.process.Environ.Map,
) AcquireError!Located {
    return switch (builtin.os.tag) {
        .macos => locateMacos(gpa, io, env_map),
        else => AcquireError.UnsupportedPlatform,
    };
}

const PREFS_DOMAIN = "com.superlogical.rex";
const APP_NAMES = [_][]const u8{ "Rex Beta.app", "Rex.app" };
const THEMES_SUBPATH = "Contents/Resources/SuperUI_SuperDesignTokens.bundle/Contents/Resources/themes.json";
const THEMES_MAX_BYTES = 16 * 1024 * 1024;
const CUSTOM_THEMES_KEY = "Workspace.customThemes";
const PREFS_EXPORT_MAX_BYTES = 16 * 1024 * 1024;

fn locateMacos(
    gpa: std.mem.Allocator,
    io: std.Io,
    env_map: *const std.process.Environ.Map,
) AcquireError!Located {
    // Rex's own Auto/Light/Dark override first; ask the system only when it
    // doesn't force one.
    const rex_appearance = try defaultsRead(gpa, io, PREFS_DOMAIN, "Workspace.appearance");
    defer if (rex_appearance) |v| gpa.free(v);
    const forced = if (rex_appearance) |a|
        std.ascii.eqlIgnoreCase(a, "dark") or std.ascii.eqlIgnoreCase(a, "light")
    else
        false;
    const system_style = if (forced) null else try defaultsRead(gpa, io, "-g", "AppleInterfaceStyle");
    defer if (system_style) |v| gpa.free(v);

    const key = switch (resolveScheme(rex_appearance, system_style)) {
        .dark => "Workspace.darkThemeID",
        .light => "Workspace.lightThemeID",
    };
    const theme_id = (try defaultsRead(gpa, io, PREFS_DOMAIN, key)) orelse {
        setDetail("{s} is not set in the {s} preferences", .{ key, PREFS_DOMAIN });
        return AcquireError.ThemeIdMissing;
    };
    errdefer gpa.free(theme_id);

    const home = env_map.get("HOME") orelse "";
    const user_apps: ?[]u8 = if (home.len > 0) try std.fs.path.join(gpa, &.{ home, "Applications" }) else null;
    defer if (user_apps) |d| gpa.free(d);
    const app_dirs = [_]?[]const u8{ "/Applications", user_apps };

    for (app_dirs) |maybe_dir| {
        const dir = maybe_dir orelse continue;
        for (APP_NAMES) |app| {
            const path = try std.fs.path.join(gpa, &.{ dir, app, THEMES_SUBPATH });
            const text = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(THEMES_MAX_BYTES)) catch |err| {
                gpa.free(path);
                if (err == error.OutOfMemory) return AcquireError.OutOfMemory;
                continue;
            };
            return .{ .theme_id = theme_id, .themes_path = path, .themes_json = text };
        }
    }
    // No bundle: a custom theme can still resolve, so this isn't fatal yet.
    return .{ .theme_id = theme_id, .themes_path = null, .themes_json = null };
}

/// JSON text of Rex's custom (imported / user-made) themes, or null when
/// there are none or they can't be read.
fn readCustomThemes(gpa: std.mem.Allocator, io: std.Io) error{OutOfMemory}!?[]u8 {
    return switch (builtin.os.tag) {
        .macos => readCustomThemesMacos(gpa, io),
        else => null,
    };
}

/// The value is plist data, which `defaults read` truncates; `defaults
/// export` prints the whole domain as an XML plist with data in base64.
fn readCustomThemesMacos(gpa: std.mem.Allocator, io: std.Io) error{OutOfMemory}!?[]u8 {
    const xml = (try defaultsRun(gpa, io, &.{ "/usr/bin/defaults", "export", PREFS_DOMAIN, "-" }, PREFS_EXPORT_MAX_BYTES)) orelse return null;
    defer gpa.free(xml);
    return extractPlistData(gpa, xml, CUSTOM_THEMES_KEY);
}

/// The base64 `<data>` value of a top-level `key` in an XML plist, decoded.
/// Null when the key is absent, its value isn't non-empty `<data>`, or the
/// base64 is invalid. A plain scan is enough: plist text escapes `<`, so the
/// `<key>…</key>` marker can only be a real key element.
fn extractPlistData(gpa: std.mem.Allocator, xml: []const u8, key: []const u8) error{OutOfMemory}!?[]u8 {
    const marker = try std.fmt.allocPrint(gpa, "<key>{s}</key>", .{key});
    defer gpa.free(marker);
    const at = std.mem.indexOf(u8, xml, marker) orelse return null;
    const ws = " \t\r\n";
    const rest = std.mem.trimStart(u8, xml[at + marker.len ..], ws);
    const open = "<data>";
    if (!std.mem.startsWith(u8, rest, open)) return null;
    const body_and_tail = rest[open.len..];
    const end = std.mem.indexOf(u8, body_and_tail, "</data>") orelse return null;
    const b64 = body_and_tail[0..end];

    const decoder = std.base64.standard.decoderWithIgnore(ws);
    const buf = try gpa.alloc(u8, decoder.calcSizeUpperBound(b64.len));
    defer gpa.free(buf);
    const n = decoder.decode(buf, b64) catch return null;
    if (n == 0) return null;
    return try gpa.dupe(u8, buf[0..n]);
}

/// `defaults read <domain> <key>`, trimmed. Null when the key is absent or
/// `defaults` can't be run.
fn defaultsRead(
    gpa: std.mem.Allocator,
    io: std.Io,
    domain: []const u8,
    key: []const u8,
) error{OutOfMemory}!?[]u8 {
    const out = (try defaultsRun(gpa, io, &.{ "/usr/bin/defaults", "read", domain, key }, 64 * 1024)) orelse return null;
    defer gpa.free(out);
    const value = std.mem.trim(u8, out, " \t\r\n");
    if (value.len == 0) return null;
    return try gpa.dupe(u8, value);
}

/// Run a `defaults` command and return its stdout (caller frees). Null when
/// it can't be run, times out, exits non-zero, or prints more than
/// `stdout_max` bytes.
fn defaultsRun(
    gpa: std.mem.Allocator,
    io: std.Io,
    argv: []const []const u8,
    stdout_max: usize,
) error{OutOfMemory}!?[]u8 {
    const run_result = std.process.run(gpa, io, .{
        .argv = argv,
        .stdout_limit = .limited(stdout_max),
        .stderr_limit = .limited(64 * 1024),
        .timeout = .{ .duration = .{ .raw = .fromSeconds(5), .clock = .awake } },
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    defer gpa.free(run_result.stderr);
    const ok = switch (run_result.term) {
        .exited => |code| code == 0,
        else => false,
    };
    if (!ok) {
        gpa.free(run_result.stdout);
        return null;
    }
    return run_result.stdout;
}

/// Subset of a `themes.json` entry. Every field is optional so one odd entry
/// can't break the lookup of another; the selected entry is validated in
/// `parseThemes`.
const ThemeEntry = struct {
    id: ?[]const u8 = null,
    name: ?[]const u8 = null,
    source: ?Source = null,

    const Source = struct {
        background: ?[]const u8 = null,
        foreground: ?[]const u8 = null,
        cursor: ?[]const u8 = null,
        cursorText: ?[]const u8 = null,
        selectionBackground: ?[]const u8 = null,
        selectionForeground: ?[]const u8 = null,
        ansi: ?[]const []const u8 = null,
    };
};

/// Find `theme_id` in the text of Rex's `themes.json` and build a Palette.
///
/// `source.ansi[0..16]` fills indices 0..15; indices 16..255 stay null even
/// with `include_256` (Rex generates those at runtime). The six special
/// colors are optional — absent or empty means null. The selected entry must
/// have a `source` with at least 16 `ansi` colors.
pub fn parseThemes(
    gpa: std.mem.Allocator,
    json_text: []const u8,
    theme_id: []const u8,
    include_256: bool,
) AcquireError!Result {
    const parsed = std.json.parseFromSlice([]const ThemeEntry, gpa, json_text, .{
        .ignore_unknown_fields = true,
    }) catch |err| switch (err) {
        error.OutOfMemory => return AcquireError.OutOfMemory,
        else => return AcquireError.MalformedThemes,
    };
    defer parsed.deinit();

    const entry = for (parsed.value) |e| {
        if (e.id) |id| if (std.mem.eql(u8, id, theme_id)) break e;
    } else return AcquireError.ThemeNotFound;

    const src = entry.source orelse return AcquireError.MalformedThemes;
    const ansi = src.ansi orelse return AcquireError.MalformedThemes;
    if (ansi.len < 16) return AcquireError.MalformedThemes;

    const palette_len: usize = if (include_256) 256 else 16;
    const indexed = try gpa.alloc(?palette_mod.Color, palette_len);
    errdefer gpa.free(indexed);
    @memset(indexed, null);
    for (ansi[0..16], 0..) |hex, i| indexed[i] = try parseHexColor(hex);

    const pal = palette_mod.Palette{
        .indexed = indexed,
        .foreground = try parseOptionalColor(src.foreground),
        .background = try parseOptionalColor(src.background),
        .cursor = try parseOptionalColor(src.cursor),
        .cursor_text = try parseOptionalColor(src.cursorText),
        .selection_background = try parseOptionalColor(src.selectionBackground),
        .selection_foreground = try parseOptionalColor(src.selectionForeground),
    };

    const theme: ?[]u8 = if (entry.name) |n| (if (n.len > 0) try gpa.dupe(u8, n) else null) else null;

    return Result{ .palette = pal, .theme = theme, .indexed_owner = indexed };
}

fn parseOptionalColor(s: ?[]const u8) AcquireError!?palette_mod.Color {
    const v = s orelse return null;
    if (v.len == 0) return null;
    return try parseHexColor(v);
}

fn parseHexColor(s: []const u8) AcquireError!palette_mod.Color {
    const body = if (s.len > 0 and s[0] == '#') s[1..] else s;
    if (body.len != 6) return AcquireError.MalformedThemes;
    const r = std.fmt.parseInt(u8, body[0..2], 16) catch return AcquireError.MalformedThemes;
    const g = std.fmt.parseInt(u8, body[2..4], 16) catch return AcquireError.MalformedThemes;
    const b = std.fmt.parseInt(u8, body[4..6], 16) catch return AcquireError.MalformedThemes;
    return .{ .r = r, .g = g, .b = b };
}

/// A color as Rex stores it in a custom theme: 0..1 float channels. `alpha`
/// and `colorSpace` are ignored, so a non-sRGB color is read as if it were sRGB.
const CustomColor = struct {
    red: f64,
    green: f64,
    blue: f64,

    fn toColor(self: CustomColor) palette_mod.Color {
        return .{ .r = channel(self.red), .g = channel(self.green), .b = channel(self.blue) };
    }

    fn channel(x: f64) u8 {
        if (!(x > 0)) return 0; // also catches NaN
        if (x >= 1) return 255;
        return @intFromFloat(@round(x * 255));
    }
};

/// Subset of a `Workspace.customThemes` entry. `paletteOverrides` is left out
/// on purpose: its shape is unverified, so it is never read.
const CustomEntry = struct {
    name: ?[]const u8 = null,
    palette: ?Colors = null,

    const Colors = struct {
        ansi: ?[]const CustomColor = null,
        background: ?CustomColor = null,
        foreground: ?CustomColor = null,
        cursor: ?CustomColor = null,
        cursorText: ?CustomColor = null,
        selectionBackground: ?CustomColor = null,
        selectionForeground: ?CustomColor = null,
        /// Index (decimal string) -> color; Rex stores 16..255 here.
        paletteBase: ?std.json.ArrayHashMap(CustomColor) = null,
    };
};

/// Find `theme_id` in the JSON text of Rex's `Workspace.customThemes`
/// preference (imported / user-made themes) and build a Palette.
///
/// `palette.ansi[0..16]` fills indices 0..15. With `include_256`, indices
/// 16..255 come from `palette.paletteBase` where present. Only the selected
/// entry is type-checked, so an odd entry can't break the lookup of another.
pub fn parseCustomThemes(
    gpa: std.mem.Allocator,
    json_text: []const u8,
    theme_id: []const u8,
    include_256: bool,
) AcquireError!Result {
    const doc = std.json.parseFromSlice(std.json.Value, gpa, json_text, .{}) catch |err| switch (err) {
        error.OutOfMemory => return AcquireError.OutOfMemory,
        else => return AcquireError.MalformedCustomThemes,
    };
    defer doc.deinit();

    const entries = switch (doc.value) {
        .array => |a| a.items,
        else => return AcquireError.MalformedCustomThemes,
    };
    const entry_value = for (entries) |e| {
        if (e != .object) continue;
        const id = e.object.get("id") orelse continue;
        if (id == .string and std.mem.eql(u8, id.string, theme_id)) break e;
    } else return AcquireError.ThemeNotFound;

    const parsed = std.json.parseFromValue(CustomEntry, gpa, entry_value, .{
        .ignore_unknown_fields = true,
    }) catch |err| switch (err) {
        error.OutOfMemory => return AcquireError.OutOfMemory,
        else => return AcquireError.MalformedCustomThemes,
    };
    defer parsed.deinit();
    const entry = parsed.value;

    const colors = entry.palette orelse return AcquireError.MalformedCustomThemes;
    const ansi = colors.ansi orelse return AcquireError.MalformedCustomThemes;
    if (ansi.len < 16) return AcquireError.MalformedCustomThemes;

    const palette_len: usize = if (include_256) 256 else 16;
    const indexed = try gpa.alloc(?palette_mod.Color, palette_len);
    errdefer gpa.free(indexed);
    @memset(indexed, null);
    for (ansi[0..16], 0..) |c, i| indexed[i] = c.toColor();

    if (include_256) if (colors.paletteBase) |base| {
        var it = base.map.iterator();
        while (it.next()) |kv| {
            const i = parsePaletteIndex(kv.key_ptr.*) orelse continue;
            if (i < 16) continue; // `ansi` owns 0..15
            indexed[i] = kv.value_ptr.toColor();
        }
    };

    const pal = palette_mod.Palette{
        .indexed = indexed,
        .foreground = customOptional(colors.foreground),
        .background = customOptional(colors.background),
        .cursor = customOptional(colors.cursor),
        .cursor_text = customOptional(colors.cursorText),
        .selection_background = customOptional(colors.selectionBackground),
        .selection_foreground = customOptional(colors.selectionForeground),
    };

    const theme: ?[]u8 = if (entry.name) |n| (if (n.len > 0) try gpa.dupe(u8, n) else null) else null;

    return Result{ .palette = pal, .theme = theme, .indexed_owner = indexed };
}

fn customOptional(c: ?CustomColor) ?palette_mod.Color {
    return if (c) |v| v.toColor() else null;
}

/// Strict decimal 0..255; anything else is not a palette index.
fn parsePaletteIndex(key: []const u8) ?usize {
    if (key.len == 0 or key.len > 3) return null;
    for (key) |ch| if (!std.ascii.isDigit(ch)) return null;
    const i = std.fmt.parseInt(usize, key, 10) catch return null;
    return if (i <= 255) i else null;
}

// ===== tests =====

const fixture = @embedFile("fixtures/rex-themes.json");

fn expectColor(expected: palette_mod.Color, actual: ?palette_mod.Color) !void {
    try std.testing.expectEqual(expected, actual.?);
}

test "fixture theme: palette, specials and display name" {
    var result = try parseThemes(std.testing.allocator, fixture, "fixture-dark", false);
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 16), result.palette.indexed.len);
    for (result.palette.indexed) |c| try std.testing.expect(c != null);
    try expectColor(.{ .r = 0x00, .g = 0x00, .b = 0x01 }, result.palette.indexed[0]);
    try expectColor(.{ .r = 0xff, .g = 0x00, .b = 0x0a }, result.palette.indexed[9]);
    try expectColor(.{ .r = 0xff, .g = 0xff, .b = 0xf0 }, result.palette.indexed[15]);

    try expectColor(.{ .r = 0xd0, .g = 0xd4, .b = 0xd8 }, result.palette.foreground);
    try expectColor(.{ .r = 0x10, .g = 0x14, .b = 0x18 }, result.palette.background);
    try expectColor(.{ .r = 0x33, .g = 0x77, .b = 0xee }, result.palette.cursor);
    try expectColor(.{ .r = 0xf0, .g = 0xf4, .b = 0xf8 }, result.palette.cursor_text);
    try expectColor(.{ .r = 0x2a, .g = 0x35, .b = 0x40 }, result.palette.selection_background);
    try expectColor(.{ .r = 0xfa, .g = 0xfb, .b = 0xfc }, result.palette.selection_foreground);

    try std.testing.expectEqualStrings("Fixture Dark", result.theme.?);
}

test "lookup selects by id, not position" {
    var result = try parseThemes(std.testing.allocator, fixture, "fixture-light", false);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("Fixture Light", result.theme.?);
    try expectColor(.{ .r = 0xfd, .g = 0xfd, .b = 0xfd }, result.palette.background);
}

test "include_256 leaves 16..255 null" {
    var result = try parseThemes(std.testing.allocator, fixture, "fixture-dark", true);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 256), result.palette.indexed.len);
    for (result.palette.indexed[0..16]) |c| try std.testing.expect(c != null);
    for (result.palette.indexed[16..]) |c| try std.testing.expect(c == null);
}

test "missing or empty optional colors are null" {
    var result = try parseThemes(std.testing.allocator, fixture, "fixture-sparse", false);
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(result.palette.foreground != null);
    try std.testing.expect(result.palette.cursor == null);
    try std.testing.expect(result.palette.cursor_text == null);
    try std.testing.expect(result.palette.selection_background == null);
    try std.testing.expect(result.palette.selection_foreground == null);
}

test "unknown theme id" {
    try std.testing.expectError(
        AcquireError.ThemeNotFound,
        parseThemes(std.testing.allocator, fixture, "no-such-theme", false),
    );
}

test "malformed json" {
    try std.testing.expectError(
        AcquireError.MalformedThemes,
        parseThemes(std.testing.allocator, "[{\"id\": ", "x", false),
    );
    try std.testing.expectError(
        AcquireError.MalformedThemes,
        parseThemes(std.testing.allocator, "{\"id\": \"x\"}", "x", false),
    );
}

test "selected entry with short ansi, no source, or bad hex is malformed" {
    try std.testing.expectError(
        AcquireError.MalformedThemes,
        parseThemes(std.testing.allocator, fixture, "fixture-short-ansi", false),
    );
    try std.testing.expectError(
        AcquireError.MalformedThemes,
        parseThemes(std.testing.allocator, "[{\"id\":\"x\"}]", "x", false),
    );
    const bad_hex =
        \\[{"id":"x","source":{"foreground":"#zzzzzz","ansi":[
        \\"#000000","#000000","#000000","#000000","#000000","#000000","#000000","#000000",
        \\"#000000","#000000","#000000","#000000","#000000","#000000","#000000","#000000"]}}]
    ;
    try std.testing.expectError(
        AcquireError.MalformedThemes,
        parseThemes(std.testing.allocator, bad_hex, "x", false),
    );
}

const custom_fixture = @embedFile("fixtures/rex-custom-themes.json");

test "custom theme: palette, specials and display name" {
    var result = try parseCustomThemes(std.testing.allocator, custom_fixture, "custom-monokai", false);
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 16), result.palette.indexed.len);
    const expected = [16]palette_mod.Color{
        .{ .r = 0x2d, .g = 0x2a, .b = 0x2e }, .{ .r = 0xff, .g = 0x61, .b = 0x88 },
        .{ .r = 0xa9, .g = 0xdc, .b = 0x76 }, .{ .r = 0xff, .g = 0xd8, .b = 0x66 },
        .{ .r = 0xfc, .g = 0x98, .b = 0x67 }, .{ .r = 0xab, .g = 0x9d, .b = 0xf2 },
        .{ .r = 0x78, .g = 0xdc, .b = 0xe8 }, .{ .r = 0xfc, .g = 0xfc, .b = 0xfa },
        .{ .r = 0x72, .g = 0x70, .b = 0x72 }, .{ .r = 0xff, .g = 0x61, .b = 0x88 },
        .{ .r = 0xa9, .g = 0xdc, .b = 0x76 }, .{ .r = 0xff, .g = 0xd8, .b = 0x66 },
        .{ .r = 0xfc, .g = 0x98, .b = 0x67 }, .{ .r = 0xab, .g = 0x9d, .b = 0xf2 },
        .{ .r = 0x78, .g = 0xdc, .b = 0xe8 }, .{ .r = 0xfc, .g = 0xfc, .b = 0xfa },
    };
    for (expected, result.palette.indexed) |e, a| try expectColor(e, a);

    try expectColor(.{ .r = 0xfc, .g = 0xfc, .b = 0xfa }, result.palette.foreground);
    try expectColor(.{ .r = 0x2d, .g = 0x2a, .b = 0x2e }, result.palette.background);
    try expectColor(.{ .r = 0xc1, .g = 0xc0, .b = 0xc0 }, result.palette.cursor);
    try expectColor(.{ .r = 0x8e, .g = 0x8d, .b = 0x8d }, result.palette.cursor_text);
    try expectColor(.{ .r = 0x5b, .g = 0x59, .b = 0x5c }, result.palette.selection_background);
    try expectColor(.{ .r = 0xfc, .g = 0xfc, .b = 0xfa }, result.palette.selection_foreground);

    try std.testing.expectEqualStrings("Monokai Pro", result.theme.?);
}

test "custom theme: include_256 fills from paletteBase, ignoring junk and low keys" {
    var result = try parseCustomThemes(std.testing.allocator, custom_fixture, "custom-monokai", true);
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 256), result.palette.indexed.len);
    try expectColor(.{ .r = 0x00, .g = 0x00, .b = 0x00 }, result.palette.indexed[16]);
    try expectColor(.{ .r = 0xff, .g = 0x00, .b = 0x00 }, result.palette.indexed[196]);
    try expectColor(.{ .r = 0xee, .g = 0xee, .b = 0xee }, result.palette.indexed[255]);
    // paletteBase["3"] disagrees with ansi[3]; ansi wins.
    try expectColor(.{ .r = 0xff, .g = 0xd8, .b = 0x66 }, result.palette.indexed[3]);
    // paletteOverrides["1"] is present (and oddly shaped); it is never read.
    try expectColor(.{ .r = 0xff, .g = 0x61, .b = 0x88 }, result.palette.indexed[1]);

    var filled: usize = 0;
    for (result.palette.indexed[16..]) |c| {
        if (c != null) filled += 1;
    }
    try std.testing.expectEqual(@as(usize, 3), filled);
}

test "custom theme: include_256 without paletteBase leaves 16..255 null" {
    var result = try parseCustomThemes(std.testing.allocator, custom_fixture, "custom-sparse", true);
    defer result.deinit(std.testing.allocator);
    for (result.palette.indexed[0..16]) |c| try std.testing.expect(c != null);
    for (result.palette.indexed[16..]) |c| try std.testing.expect(c == null);
}

test "custom theme: absent or null specials are null" {
    var result = try parseCustomThemes(std.testing.allocator, custom_fixture, "custom-sparse", false);
    defer result.deinit(std.testing.allocator);
    try expectColor(.{ .r = 0xff, .g = 0xff, .b = 0xff }, result.palette.background);
    try expectColor(.{ .r = 0x00, .g = 0x00, .b = 0x00 }, result.palette.foreground);
    try std.testing.expect(result.palette.cursor == null);
    try std.testing.expect(result.palette.cursor_text == null);
    try std.testing.expect(result.palette.selection_background == null);
    try std.testing.expect(result.palette.selection_foreground == null);
    try std.testing.expectEqualStrings("Sparse", result.theme.?);
}

test "custom theme: channels round and clamp; alpha and colorSpace are ignored" {
    var result = try parseCustomThemes(std.testing.allocator, custom_fixture, "custom-rounding", false);
    defer result.deinit(std.testing.allocator);
    try expectColor(.{ .r = 128, .g = 255, .b = 0 }, result.palette.indexed[0]);
    try expectColor(.{ .r = 255, .g = 0, .b = 255 }, result.palette.indexed[1]); // integer channels
    try expectColor(.{ .r = 127, .g = 128, .b = 255 }, result.palette.indexed[2]);
    // display-p3 with alpha 0.5: channels taken as-is.
    try expectColor(.{ .r = 26, .g = 51, .b = 77 }, result.palette.background);
    try std.testing.expect(result.theme == null); // empty name
}

test "custom theme: unknown id" {
    try std.testing.expectError(
        AcquireError.ThemeNotFound,
        parseCustomThemes(std.testing.allocator, custom_fixture, "custom-nope", false),
    );
    // The entry whose id is the number 42 is not matched by the string "42".
    try std.testing.expectError(
        AcquireError.ThemeNotFound,
        parseCustomThemes(std.testing.allocator, custom_fixture, "42", false),
    );
    try std.testing.expectError(
        AcquireError.ThemeNotFound,
        parseCustomThemes(std.testing.allocator, "[]", "x", false),
    );
}

test "custom theme: malformed blob or selected entry" {
    const a = std.testing.allocator;
    const E = AcquireError.MalformedCustomThemes;
    try std.testing.expectError(E, parseCustomThemes(a, "[{\"id\": ", "x", false));
    try std.testing.expectError(E, parseCustomThemes(a, "{\"id\": \"x\"}", "x", false));
    try std.testing.expectError(E, parseCustomThemes(a, "", "x", false));
    try std.testing.expectError(E, parseCustomThemes(a, custom_fixture, "custom-short-ansi", false));
    try std.testing.expectError(E, parseCustomThemes(a, custom_fixture, "custom-missing-channel", false));
    try std.testing.expectError(E, parseCustomThemes(a, custom_fixture, "custom-no-palette", false));
    try std.testing.expectError(E, parseCustomThemes(a, "[{\"id\":\"x\",\"palette\":\"nope\"}]", "x", false));
}

test "extractPlistData: decodes wrapped, indented base64" {
    const a = std.testing.allocator;
    const xml =
        \\<plist version="1.0">
        \\<dict>
        \\    <key>Workspace.appearance</key>
        \\    <string>system</string>
        \\    <key>Workspace.customThemes</key>
        \\    <data>
        \\    W3siaWQiOiJj
        \\    dXN0b20teCJ9XQ==
        \\    </data>
        \\    <key>Other</key>
        \\    <data>
        \\    AAAA
        \\    </data>
        \\</dict>
        \\</plist>
    ;
    const got = (try extractPlistData(a, xml, "Workspace.customThemes")).?;
    defer a.free(got);
    try std.testing.expectEqualStrings("[{\"id\":\"custom-x\"}]", got);

    // Tab-indented, as `defaults export` really prints it.
    const tabbed = (try extractPlistData(a, "<dict>\n\t<key>K</key>\n\t<data>\n\tQUJD\n\tREVG\n\t</data>\n</dict>", "K")).?;
    defer a.free(tabbed);
    try std.testing.expectEqualStrings("ABCDEF", tabbed);
}

test "extractPlistData: absent key, wrong type, near-miss key names, bad or empty data" {
    const a = std.testing.allocator;
    const k = "Workspace.customThemes";
    try std.testing.expect(try extractPlistData(a, "<dict><key>Other</key><data>AAAA</data></dict>", k) == null);
    try std.testing.expect(try extractPlistData(a, "<dict><key>Workspace.customThemes</key><string>AAAA</string></dict>", k) == null);
    try std.testing.expect(try extractPlistData(a, "<dict><key>Workspace.customThemesOld</key><data>AAAA</data></dict>", k) == null);
    try std.testing.expect(try extractPlistData(a, "<dict><key>My.Workspace.customThemes</key><data>AAAA</data></dict>", k) == null);
    // The key text inside a string value is escaped, so it can't match.
    try std.testing.expect(try extractPlistData(a, "<dict><key>X</key><string>&lt;key&gt;Workspace.customThemes&lt;/key&gt;</string></dict>", k) == null);
    try std.testing.expect(try extractPlistData(a, "<dict><key>Workspace.customThemes</key><data>!!!!</data></dict>", k) == null);
    try std.testing.expect(try extractPlistData(a, "<dict><key>Workspace.customThemes</key><data>AAA</data></dict>", k) == null);
    try std.testing.expect(try extractPlistData(a, "<dict><key>Workspace.customThemes</key><data/></dict>", k) == null);
    try std.testing.expect(try extractPlistData(a, "<dict><key>Workspace.customThemes</key><data></data></dict>", k) == null);
    try std.testing.expect(try extractPlistData(a, "<dict><key>Workspace.customThemes</key><data>AAAA", k) == null);
    try std.testing.expect(try extractPlistData(a, "", k) == null);
}

test "resolveTheme: built-in first, then custom" {
    const a = std.testing.allocator;

    // Built-in ID with both sources: the bundle wins.
    var r1 = try resolveTheme(a, fixture, custom_fixture, "fixture-dark", false);
    defer r1.deinit(a);
    try std.testing.expectEqualStrings("Fixture Dark", r1.theme.?);

    // Custom ID with a bundle that doesn't have it.
    var r2 = try resolveTheme(a, fixture, custom_fixture, "custom-monokai", false);
    defer r2.deinit(a);
    try std.testing.expectEqualStrings("Monokai Pro", r2.theme.?);

    // Custom ID with no bundle at all.
    var r3 = try resolveTheme(a, null, custom_fixture, "custom-monokai", true);
    defer r3.deinit(a);
    try std.testing.expectEqualStrings("Monokai Pro", r3.theme.?);
    try std.testing.expectEqual(@as(usize, 256), r3.palette.indexed.len);
}

test "resolveTheme: failures" {
    const a = std.testing.allocator;
    const E = AcquireError;
    // In neither place.
    try std.testing.expectError(E.ThemeNotFound, resolveTheme(a, fixture, custom_fixture, "nope", false));
    // Bundle miss, no custom themes stored.
    try std.testing.expectError(E.ThemeNotFound, resolveTheme(a, fixture, null, "custom-monokai", false));
    // No bundle: the app is what's missing.
    try std.testing.expectError(E.AppNotFound, resolveTheme(a, null, custom_fixture, "nope", false));
    try std.testing.expectError(E.AppNotFound, resolveTheme(a, null, null, "fixture-dark", false));
    // A malformed bundle is reported, not papered over by a valid custom theme.
    try std.testing.expectError(E.MalformedThemes, resolveTheme(a, "[{", custom_fixture, "custom-monokai", false));
    // Bad custom blob or bad selected entry.
    try std.testing.expectError(E.MalformedCustomThemes, resolveTheme(a, fixture, "not json", "custom-monokai", false));
    try std.testing.expectError(E.MalformedCustomThemes, resolveTheme(a, null, custom_fixture, "custom-short-ansi", false));
}

test "resolveScheme: rex override wins, else system" {
    try std.testing.expectEqual(Scheme.dark, resolveScheme("dark", null));
    try std.testing.expectEqual(Scheme.light, resolveScheme("light", "Dark"));
    try std.testing.expectEqual(Scheme.dark, resolveScheme("Dark", null));
    try std.testing.expectEqual(Scheme.dark, resolveScheme(null, "Dark"));
    try std.testing.expectEqual(Scheme.light, resolveScheme(null, null));
    try std.testing.expectEqual(Scheme.dark, resolveScheme("auto", "Dark"));
    try std.testing.expectEqual(Scheme.light, resolveScheme("system", null));
}

test {
    // `acquire` needs a real Rex install, so it has no behavior test here;
    // this at least keeps it compiling on every platform.
    std.testing.refAllDecls(@This());
}
