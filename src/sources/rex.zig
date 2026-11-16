//! Rex source: resolves the active theme ID from Rex's preferences and looks
//! it up in the `themes.json` shipped inside the Rex app bundle. No TTY
//! required. Relies on undocumented Rex internals (prefs keys, bundle layout,
//! `themes.json` schema) and only knows the built-in themes.

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

    return parseThemes(gpa, loc.themes_json, loc.theme_id, opts.include_256) catch |err| {
        switch (err) {
            AcquireError.ThemeNotFound => setDetail("theme '{s}' is not in {s} (custom themes are not supported)", .{ loc.theme_id, loc.themes_path }),
            AcquireError.MalformedThemes => setDetail("{s}", .{loc.themes_path}),
            else => {},
        }
        return err;
    };
}

/// Everything that depends on where a given platform's Rex keeps its state.
const Located = struct {
    theme_id: []u8,
    themes_path: []u8,
    themes_json: []u8,

    fn deinit(self: *Located, gpa: std.mem.Allocator) void {
        gpa.free(self.theme_id);
        gpa.free(self.themes_path);
        gpa.free(self.themes_json);
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
    setDetail("no readable themes.json in 'Rex Beta.app' or 'Rex.app' under /Applications or ~/Applications", .{});
    return AcquireError.AppNotFound;
}

/// `defaults read <domain> <key>`, trimmed. Null when the key is absent or
/// `defaults` can't be run.
fn defaultsRead(
    gpa: std.mem.Allocator,
    io: std.Io,
    domain: []const u8,
    key: []const u8,
) error{OutOfMemory}!?[]u8 {
    const argv = [_][]const u8{ "/usr/bin/defaults", "read", domain, key };
    const run_result = std.process.run(gpa, io, .{ .argv = &argv }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    defer gpa.free(run_result.stdout);
    defer gpa.free(run_result.stderr);
    switch (run_result.term) {
        .exited => |code| if (code != 0) return null,
        else => return null,
    }
    const value = std.mem.trim(u8, run_result.stdout, " \t\r\n");
    if (value.len == 0) return null;
    return try gpa.dupe(u8, value);
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
