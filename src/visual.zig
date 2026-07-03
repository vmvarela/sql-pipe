//! UTF-8 display-width helpers shared by table.zig and markdown.zig.
//!
//! Provides:
//!   utf8CharLen, utf8DecodeRaw, isWideCodepoint — low-level UTF-8 inspection
//!   visualWidth — terminal display width of a string (CJK = 2, ASCII = 1)
//!   writeCharRepeated, writeSpaces — efficient repeated-string output

const std = @import("std");

// Ranges with terminal display width 2. Covers Unicode East Asian Width W/F
// plus common Emoji ranges treated as wide by terminals.
// ponytail: emoji ranges are a terminal convention override, not UAX #11 W/F
const wide_ranges = blk: {
    var ranges = [_][2]u21{
        // CJK and related blocks (UAX #11 Wide)
        .{ 0x1100, 0x115F },
        .{ 0x2329, 0x232A },
        .{ 0x2E80, 0x2EFF },
        .{ 0x2F00, 0x2FDF },
        .{ 0x2FF0, 0x2FFF },
        .{ 0x3000, 0x303E },
        .{ 0x3041, 0x3096 },
        .{ 0x3099, 0x30FF },
        .{ 0x3105, 0x312F },
        .{ 0x3131, 0x318E },
        .{ 0x3190, 0x31E3 },
        .{ 0x31F0, 0x321E },
        .{ 0x3220, 0x3247 },
        .{ 0x3250, 0x4DBF },
        .{ 0x4E00, 0x9FFF },
        .{ 0xA000, 0xA48C },
        .{ 0xA490, 0xA4C6 },
        .{ 0xA960, 0xA97C },
        .{ 0xAC00, 0xD7FF },
        .{ 0xF900, 0xFAFF },
        .{ 0xFE10, 0xFE19 },
        .{ 0xFE30, 0xFE6F },
        .{ 0xFF01, 0xFF60 },
        .{ 0xFFE0, 0xFFE6 },

        // CJK Extension B and beyond
        .{ 0x1B000, 0x1B0FF },
        .{ 0x1B100, 0x1B12F },
        .{ 0x1B130, 0x1B16F },
        .{ 0x1F200, 0x1F2FF },
        .{ 0x20000, 0x2A6DF },
        .{ 0x2A700, 0x2B739 },
        .{ 0x2B740, 0x2B81D },
        .{ 0x2B820, 0x2CEA1 },
        .{ 0x2CEB0, 0x2EBE0 },
        .{ 0x2F800, 0x2FA1F },
        .{ 0x30000, 0x3134A },
        .{ 0x31350, 0x323AF },

        // Common Emoji ranges (width 2 in terminals)
        .{ 0x231A, 0x231B },
        .{ 0x23E9, 0x23EC },
        .{ 0x23F0, 0x23F3 },
        .{ 0x25FD, 0x25FE },
        .{ 0x2614, 0x2615 },
        .{ 0x2648, 0x2653 },
        .{ 0x267F, 0x267F },
        .{ 0x2693, 0x2693 },
        .{ 0x26A1, 0x26A1 },
        .{ 0x26AA, 0x26AB },
        .{ 0x26BD, 0x26BE },
        .{ 0x26C4, 0x26C5 },
        .{ 0x26CE, 0x26CE },
        .{ 0x26D4, 0x26D4 },
        .{ 0x26EA, 0x26EA },
        .{ 0x26F2, 0x26F3 },
        .{ 0x26F5, 0x26F5 },
        .{ 0x26FA, 0x26FA },
        .{ 0x26FD, 0x26FD },
        .{ 0x2702, 0x2702 },
        .{ 0x2705, 0x2705 },
        .{ 0x2708, 0x270D },
        .{ 0x270F, 0x270F },
        .{ 0x2712, 0x2712 },
        .{ 0x2714, 0x2714 },
        .{ 0x2716, 0x2716 },
        .{ 0x271D, 0x271D },
        .{ 0x2721, 0x2721 },
        .{ 0x2728, 0x2728 },
        .{ 0x2733, 0x2734 },
        .{ 0x2744, 0x2744 },
        .{ 0x2747, 0x2747 },
        .{ 0x274C, 0x274C },
        .{ 0x274E, 0x274E },
        .{ 0x2753, 0x2755 },
        .{ 0x2757, 0x2757 },
        .{ 0x2763, 0x2764 },
        .{ 0x2795, 0x2797 },
        .{ 0x27A1, 0x27A1 },
        .{ 0x27B0, 0x27B0 },
        .{ 0x27BF, 0x27BF },
        .{ 0x2934, 0x2935 },
        .{ 0x2B05, 0x2B07 },
        .{ 0x2B1B, 0x2B1C },
        .{ 0x2B50, 0x2B50 },
        .{ 0x2B55, 0x2B55 },
        .{ 0x3030, 0x3030 },
        .{ 0x303D, 0x303D },
        .{ 0x3297, 0x3297 },
        .{ 0x3299, 0x3299 },
        .{ 0x1F000, 0x1F02F },
        .{ 0x1F030, 0x1F09F },
        .{ 0x1F0A0, 0x1F0FF },
        .{ 0x1F100, 0x1F1FF },
        .{ 0x1F300, 0x1FAFF },
        .{ 0x1FB00, 0x1FBFF },
    };
    @setEvalBranchQuota(10000);
    std.sort.block([2]u21, &ranges, {}, struct {
        fn lessThan(_: void, a: [2]u21, b: [2]u21) bool {
            return a[0] < b[0];
        }
    }.lessThan);
    break :blk ranges;
};

/// Return the byte length of a UTF-8 character from its leading byte.
fn utf8CharLen(first: u8) usize {
    if (first < 0x80) return 1;
    if (first < 0xC0) return 1; // continuation or invalid byte — treat as single
    if (first < 0xE0) return 2;
    if (first < 0xF0) return 3;
    if (first < 0xF8) return 4;
    return 1; // invalid byte
}

/// Decode a raw UTF-8 sequence (1–4 bytes) into a codepoint, or null on error.
fn utf8DecodeRaw(bytes: []const u8) ?u21 {
    return switch (bytes.len) {
        1 => bytes[0],
        2 => std.unicode.utf8Decode2(bytes[0..2].*) catch null,
        3 => std.unicode.utf8Decode3(bytes[0..3].*) catch null,
        4 => std.unicode.utf8Decode4(bytes[0..4].*) catch null,
        else => null,
    };
}

/// Check whether a codepoint is wide (display width 2 in a terminal).
fn isWideCodepoint(cp: u21) bool {
    var left: usize = 0;
    var right: usize = wide_ranges.len;
    while (left < right) {
        const mid = (left + right) / 2;
        if (wide_ranges[mid][0] <= cp) {
            left = mid + 1;
        } else {
            right = mid;
        }
    }
    if (left == 0) return false;
    const range = wide_ranges[left - 1];
    return cp <= range[1];
}

/// Compute the visual display width of a UTF-8 string.
///
/// Returns the number of terminal columns the string occupies:
/// - ASCII (0x00–0x7F): width 1
/// - CJK Unified Ideographs (0x4E00–0x9FFF): width 2
/// - CJK Extension A (0x3400–0x4DBF): width 2
/// - Fullwidth Forms (0xFF00–0xFFEF): width 2
/// - Hangul Syllables (0xAC00–0xD7AF): width 2
/// - Everything else: width 1 (conservative estimate)
///
/// On decode errors, advances one byte and assumes width 1.
pub fn visualWidth(s: []const u8) usize {
    var width: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        const byte_len = utf8CharLen(s[i]);
        if (i + byte_len > s.len) {
            width += 1;
            i += 1;
            continue;
        }
        const slice = s[i..][0..byte_len];
        const codepoint = utf8DecodeRaw(slice) orelse {
            width += 1;
            i += 1;
            continue;
        };
        if (isWideCodepoint(codepoint)) {
            width += 2;
        } else {
            width += 1;
        }
        i += byte_len;
    }
    return width;
}

/// Helper: write a multi-byte UTF-8 character repeated n times.
pub fn writeCharRepeated(writer: *std.Io.Writer, char: []const u8, n: usize) error{WriteFailed}!void {
    var buf: [256]u8 = undefined;
    const char_len = char.len;
    var filled: usize = 0;
    while (filled + char_len <= buf.len) : (filled += char_len) {
        @memcpy(buf[filled..][0..char_len], char);
    }
    var remaining = n;
    while (remaining > 0) {
        const chunk = @min(remaining, filled / char_len);
        try writer.writeAll(buf[0 .. chunk * char_len]);
        remaining -= chunk;
    }
}

const spaces_buf = " " ** 256;

/// Write n space characters efficiently using a pre-filled buffer.
pub fn writeSpaces(writer: *std.Io.Writer, n: usize) error{WriteFailed}!void {
    var remaining = n;
    while (remaining > 0) {
        const chunk = @min(remaining, spaces_buf.len);
        try writer.writeAll(spaces_buf[0..chunk]);
        remaining -= chunk;
    }
}

const testing = std.testing;

test "visualWidth ASCII" {
    try testing.expectEqual(@as(usize, 0), visualWidth(""));
    try testing.expectEqual(@as(usize, 5), visualWidth("Hello"));
    try testing.expectEqual(@as(usize, 3), visualWidth("abc"));
}

test "visualWidth CJK" {
    // Each CJK character has width 2
    try testing.expectEqual(@as(usize, 8), visualWidth("你好世界"));
    try testing.expectEqual(@as(usize, 2), visualWidth("中"));
    try testing.expectEqual(@as(usize, 4), visualWidth("中文"));
}

test "visualWidth mixed" {
    // "Hello" (5) + "世界" (4) = 9
    try testing.expectEqual(@as(usize, 9), visualWidth("Hello世界"));
    // "a" (1) + "中" (2) + "b" (1) = 4
    try testing.expectEqual(@as(usize, 4), visualWidth("a中b"));
}

test "visualWidth invalid UTF-8" {
    // Invalid continuation byte treated as width 1
    try testing.expectEqual(@as(usize, 1), visualWidth(&[_]u8{0x80}));
    // Overlong encoding (invalid) — width 1 per byte
    try testing.expectEqual(@as(usize, 2), visualWidth(&[_]u8{ 0xC0, 0x80 }));
}

test "visualWidth Hiragana and Katakana" {
    try testing.expectEqual(@as(usize, 2), visualWidth("あ"));
    try testing.expectEqual(@as(usize, 2), visualWidth("カ"));
    try testing.expectEqual(@as(usize, 4), visualWidth("あい"));
}

test "visualWidth emoji" {
    try testing.expectEqual(@as(usize, 2), visualWidth("😀"));
    try testing.expectEqual(@as(usize, 4), visualWidth("😀😁"));
}

test "visualWidth misc emoji symbols" {
    try testing.expectEqual(@as(usize, 2), visualWidth("❄"));
    try testing.expectEqual(@as(usize, 2), visualWidth("⛵"));
    try testing.expectEqual(@as(usize, 2), visualWidth("♿"));
}
