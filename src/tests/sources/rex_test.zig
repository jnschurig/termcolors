const std = @import("std");
const rex = @import("../../sources/rex.zig");
const palette_mod = @import("../../palette.zig");

const AcquireError = rex.AcquireError;
const extractPlistData = rex.extractPlistData;
const parseCustomThemes = rex.parseCustomThemes;
const parseThemes = rex.parseThemes;
const resolveScheme = rex.resolveScheme;
const resolveTheme = rex.resolveTheme;
const Scheme = rex.Scheme;

const fixture = @embedFile("../fixtures/rex-themes.json");

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

const custom_fixture = @embedFile("../fixtures/rex-custom-themes.json");

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
    std.testing.refAllDecls(rex);
}
