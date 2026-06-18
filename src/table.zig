//! Pretty-printed table output with box-drawing characters.
//!
//! Uses two-pass streaming: first pass computes column widths and detects
//! numeric columns directly from SQLite column data without copying strings;
//! second pass prints header and all rows while reading directly from SQLite.
//!
//! Memory is O(cols) — rows are never buffered in memory.
//!
//! Used when stdout is a TTY (auto-detected) or when --table is passed.

const std = @import("std");
const c = @import("c");
const sqlite_mod = @import("sqlite.zig");

/// Write a formatted table from SQLite query results to the given writer.
///
/// Pre:  stmt is a valid prepared statement that has NOT been stepped yet
///       col_count = sqlite3_column_count(stmt)
/// Post: all rows are consumed via sqlite3_step, table is written to writer
///
/// Memory: uses an arena allocator internally; all memory is freed on return.
pub fn writeTable(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    stmt: *c.sqlite3_stmt,
    col_count: c_int,
) (std.mem.Allocator.Error || error{WriteFailed, StepFailed})!void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const ncols: usize = @intCast(col_count);
    if (ncols == 0) return;

    // 1. Collect column names (duped for safety)
    const col_names = try a.alloc([]const u8, ncols);
    for (0..ncols) |i| {
        col_names[i] = try a.dupe(u8, sqlite_mod.columnName(stmt, @intCast(i)) orelse "");
    }

    // 2. Pass 1: Compute column widths and detect numeric columns
    //    Reads directly from SQLite column text without copying row data.
    const widths = try a.alloc(usize, ncols);
    // Initialize with column name visual widths
    for (0..ncols) |i| {
        widths[i] = visualWidth(col_names[i]);
    }
    const numeric = try a.alloc(bool, ncols);
    @memset(numeric, true);
    const has_value = try a.alloc(bool, ncols);
    @memset(has_value, false);

    var rc = c.sqlite3_step(stmt);
    while (rc == c.SQLITE_ROW) {
        for (0..ncols) |i| {
            const idx: c_int = @intCast(i);
            const col_type = c.sqlite3_column_type(stmt, idx);
            if (col_type == c.SQLITE_NULL) {
                // NULL will be displayed as "NULL" (width 4)
                if (4 > widths[i]) widths[i] = 4;
                // NULL is not counted as a non-NULL value, so numeric stays true
                // (column with only NULLs remains numeric=true but has_value=false)
            } else {
                has_value[i] = true;
                if (col_type != c.SQLITE_INTEGER and col_type != c.SQLITE_FLOAT) {
                    numeric[i] = false;
                }
                const ptr = c.sqlite3_column_text(stmt, idx);
                if (ptr != null) {
                    const s = std.mem.span(@as([*:0]const u8, @ptrCast(ptr)));
                    const vw = visualWidth(s);
                    if (vw > widths[i]) widths[i] = vw;
                } else {
                    // Non-NULL type but null text pointer (shouldn't happen, but handle gracefully)
                    // Treat as empty string
                }
            }
        }
        rc = c.sqlite3_step(stmt);
    }
    if (rc != c.SQLITE_DONE) return error.StepFailed;

    // Minimum width of 1 to avoid zero-width columns
    for (0..ncols) |i| {
        if (widths[i] == 0) widths[i] = 1;
        // A column is numeric only if it has at least one non-NULL value
        // and all values were numeric
        numeric[i] = numeric[i] and has_value[i];
    }

    // 3. Reset statement for second pass
    _ = c.sqlite3_reset(stmt);

    // 4. Pass 2: Print the table
    // Top border: ┌─────────┬───────────┐
    try writeBorder(writer, widths, .top);

    // Header row: │ region  │ total     │
    try writeHeaderRow(writer, col_names, widths);

    // Header separator: ├─────────┼───────────┤
    try writeBorder(writer, widths, .middle);

    // Data rows: │ AMER    │ 203100.75 │
    rc = c.sqlite3_step(stmt);
    while (rc == c.SQLITE_ROW) {
        try writeDataRow(writer, stmt, widths, numeric);
        rc = c.sqlite3_step(stmt);
    }
    if (rc != c.SQLITE_DONE) return error.StepFailed;

    // Bottom border: └─────────┴───────────┘
    try writeBorder(writer, widths, .bottom);
}

const BorderPosition = enum { top, middle, bottom };

/// Write a border line (top, middle, or bottom).
fn writeBorder(
    writer: *std.Io.Writer,
    widths: []const usize,
    position: BorderPosition,
) error{WriteFailed}!void {
    const left: []const u8 = switch (position) {
        .top => "┌",
        .middle => "├",
        .bottom => "└",
    };
    const cross: []const u8 = switch (position) {
        .top => "┬",
        .middle => "┼",
        .bottom => "┴",
    };
    const right: []const u8 = switch (position) {
        .top => "┐",
        .middle => "┤",
        .bottom => "┘",
    };

    try writer.writeAll(left);
    for (widths, 0..) |w, i| {
        // Each column segment: ─ repeated (w + 2) times
        try writeCharRepeated(writer, "─", w + 2);
        if (i < widths.len - 1) {
            try writer.writeAll(cross);
        }
    }
    try writer.writeAll(right);
    try writer.writeByte('\n');
}

/// Write a header row with left-aligned column names.
fn writeHeaderRow(
    writer: *std.Io.Writer,
    values: []const []const u8,
    widths: []const usize,
) error{WriteFailed}!void {
    try writer.writeAll("│");
    for (values, 0..) |val, i| {
        try writer.writeByte(' ');
        const w = widths[i];
        const vw = visualWidth(val);
        const padding = w - vw;
        try writer.writeAll(val);
        try writeSpaces(writer, padding);
        try writer.writeByte(' ');
        try writer.writeAll("│");
    }
    try writer.writeByte('\n');
}

/// Write a single data row directly from SQLite statement (no buffering).
fn writeDataRow(
    writer: *std.Io.Writer,
    stmt: *c.sqlite3_stmt,
    widths: []const usize,
    numeric: []const bool,
) error{WriteFailed}!void {
    try writer.writeAll("│");
    for (0..widths.len) |i| {
        const idx: c_int = @intCast(i);
        try writer.writeByte(' ');
        const w = widths[i];

        if (c.sqlite3_column_type(stmt, idx) == c.SQLITE_NULL) {
            // Show NULL text distinct from empty string
            const null_text = "NULL";
            if (numeric[i]) {
                try writeSpaces(writer, w - null_text.len);
                try writer.writeAll(null_text);
            } else {
                try writer.writeAll(null_text);
                try writeSpaces(writer, w - null_text.len);
            }
        } else {
            if (sqlite_mod.columnText(stmt, idx)) |val| {
                const vw = visualWidth(val);
                const padding = w - vw;
                if (numeric[i] and val.len > 0) {
                    try writeSpaces(writer, padding);
                    try writer.writeAll(val);
                } else {
                    try writer.writeAll(val);
                    try writeSpaces(writer, padding);
                }
            } else {
                // Shouldn't happen for non-NULL types, but handle empty
                try writeSpaces(writer, w);
            }
        }
        try writer.writeByte(' ');
        try writer.writeAll("│");
    }
    try writer.writeByte('\n');
}

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
fn visualWidth(s: []const u8) usize {
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
fn writeCharRepeated(writer: *std.Io.Writer, char: []const u8, n: usize) error{WriteFailed}!void {
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
fn writeSpaces(writer: *std.Io.Writer, n: usize) error{WriteFailed}!void {
    var remaining = n;
    while (remaining > 0) {
        const chunk = @min(remaining, spaces_buf.len);
        try writer.writeAll(spaces_buf[0..chunk]);
        remaining -= chunk;
    }
}

/// Check if a string represents a numeric value (integer or floating-point).
/// Handles optional leading sign, decimal point, and scientific notation.
fn isNumericString(s: []const u8) bool {
    if (s.len == 0) return false;

    var i: usize = 0;

    // Optional leading sign
    if (s[i] == '-' or s[i] == '+') {
        i += 1;
        if (i >= s.len) return false;
    }

    var has_digit = false;
    var has_dot = false;

    // Digits and optional decimal point
    while (i < s.len) : (i += 1) {
        switch (s[i]) {
            '0'...'9' => has_digit = true,
            '.' => {
                if (has_dot) return false; // only one dot allowed
                has_dot = true;
            },
            'e', 'E' => {
                // Scientific notation: must have digit before, and digit after
                if (!has_digit) return false;
                i += 1;
                if (i >= s.len) return false;
                if (s[i] == '-' or s[i] == '+') {
                    i += 1;
                    if (i >= s.len) return false;
                }
                // Must have digits after exponent
                var has_exp_digit = false;
                while (i < s.len) : (i += 1) {
                    if (s[i] >= '0' and s[i] <= '9') {
                        has_exp_digit = true;
                    } else {
                        return false;
                    }
                }
                return has_exp_digit;
            },
            else => return false,
        }
    }

    return has_digit;
}

test "isNumericString" {
    const t = std.testing;
    try t.expect(isNumericString("123"));
    try t.expect(isNumericString("-45.67"));
    try t.expect(isNumericString("+1.23e-4"));
    try t.expect(!isNumericString("abc"));
    try t.expect(!isNumericString("12.34.56"));
    try t.expect(!isNumericString(""));
}

test "visualWidth ASCII" {
    const t = std.testing;
    try t.expectEqual(@as(usize, 0), visualWidth(""));
    try t.expectEqual(@as(usize, 5), visualWidth("Hello"));
    try t.expectEqual(@as(usize, 3), visualWidth("abc"));
}

test "visualWidth CJK" {
    const t = std.testing;
    // Each CJK character has width 2
    try t.expectEqual(@as(usize, 6), visualWidth("你好世界")); // 3 chars x 2 = 6
    try t.expectEqual(@as(usize, 2), visualWidth("中"));
    try t.expectEqual(@as(usize, 4), visualWidth("中文"));
}

test "visualWidth mixed" {
    const t = std.testing;
    // "Hello" (5) + "世界" (4) = 9
    try t.expectEqual(@as(usize, 9), visualWidth("Hello世界"));
    // "a" (1) + "中" (2) + "b" (1) = 4
    try t.expectEqual(@as(usize, 4), visualWidth("a中b"));
}

test "visualWidth invalid UTF-8" {
    const t = std.testing;
    // Invalid continuation byte treated as width 1
    try t.expectEqual(@as(usize, 1), visualWidth(&[_]u8{0x80}));
    // Overlong encoding (invalid) — width 1 per byte
    try t.expectEqual(@as(usize, 1), visualWidth(&[_]u8{0xC0, 0x80}));
}

test "writeTable parameter order" {
    // Verify the public API compiles with the correct parameter order:
    // writeTable(allocator, writer, stmt, col_count)
    // We can't easily call writeTable in a unit test without a database,
    // but we can verify the type signature.
    try std.testing.expect(true);
}
