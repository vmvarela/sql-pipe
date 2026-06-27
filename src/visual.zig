//! UTF-8 display-width helpers shared by table.zig and markdown.zig.
//!
//! Provides:
//!   utf8CharLen, utf8DecodeRaw, isWideCodepoint — low-level UTF-8 inspection
//!   visualWidth — terminal display width of a string (CJK = 2, ASCII = 1)
//!   writeCharRepeated, writeSpaces — efficient repeated-string output

const std = @import("std");

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
    return (cp >= 0x3400 and cp <= 0x4DBF) or
        (cp >= 0x4E00 and cp <= 0x9FFF) or
        (cp >= 0xAC00 and cp <= 0xD7AF) or
        (cp >= 0xFF00 and cp <= 0xFFEF);
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
        try writer.writeAll(buf[0..chunk * char_len]);
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
    try testing.expectEqual(@as(usize, 6), visualWidth("你好世界"));
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
    try testing.expectEqual(@as(usize, 1), visualWidth(&[_]u8{0xC0, 0x80}));
}
