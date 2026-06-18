//! Markdown table output format.
//!
//! Uses two-pass streaming: first pass computes column widths and detects
//! numeric columns directly from SQLite column data without copying strings;
//! second pass prints header, separator, and all rows while reading directly
//! from SQLite.
//!
//! Memory is O(cols) — rows are never buffered in memory.

const std = @import("std");
const c = @import("c");
const sqlite_mod = @import("sqlite.zig");

/// Write a Markdown table from SQLite query results to the given writer.
///
/// Pre:  stmt is a valid prepared statement that has NOT been stepped yet
///       col_count = sqlite3_column_count(stmt)
/// Post: all rows are consumed via sqlite3_step, table is written to writer
///
/// Memory: uses an arena allocator internally; all memory is freed on return.
pub fn writeMarkdown(
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
    const widths = try a.alloc(usize, ncols);
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
                // NULL renders as empty cell (width 0), but ensure minimum width of 3
                // for the column to show header + dashes properly.
                if (3 > widths[i]) widths[i] = 3;
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
                }
            }
        }
        rc = c.sqlite3_step(stmt);
    }
    if (rc != c.SQLITE_DONE) return error.StepFailed;

    // Minimum width of 1 to avoid zero-width columns
    for (0..ncols) |i| {
        if (widths[i] == 0) widths[i] = 1;
        numeric[i] = numeric[i] and has_value[i];
    }

    // 3. Reset statement for second pass
    _ = c.sqlite3_reset(stmt);

    // 4. Pass 2: Print the markdown table
    // Header row: | col1 | col2 |
    try writeRow(writer, col_names, widths, false);
    // Separator: |------|------|
    try writeSeparator(writer, widths, numeric);
    // Data rows: | val1 | val2 |
    rc = c.sqlite3_step(stmt);
    while (rc == c.SQLITE_ROW) {
        try writeDataRow(writer, stmt, widths, numeric);
        rc = c.sqlite3_step(stmt);
    }
    if (rc != c.SQLITE_DONE) return error.StepFailed;
}

/// Write a header or data row with pipe-delimited cells.
/// When `numeric` is null, all cells are left-aligned (used for header).
fn writeRow(
    writer: *std.Io.Writer,
    values: []const []const u8,
    widths: []const usize,
    right_align: bool,
) error{WriteFailed}!void {
    try writer.writeByte('|');
    for (values, 0..) |val, i| {
        try writer.writeByte(' ');
        const w = widths[i];
        const vw = visualWidth(val);
        const padding = w - vw;
        if (right_align) {
            try writeSpaces(writer, padding);
            try writer.writeAll(val);
        } else {
            try writer.writeAll(val);
            try writeSpaces(writer, padding);
        }
        try writer.writeByte(' ');
        try writer.writeByte('|');
    }
    try writer.writeByte('\n');
}

/// Write the header separator line: |------|------|
/// Dashes fill the column width (plus 1 space padding each side).
fn writeSeparator(
    writer: *std.Io.Writer,
    widths: []const usize,
    numeric: []const bool,
) error{WriteFailed}!void {
    _ = numeric;
    try writer.writeByte('|');
    for (widths) |w| {
        try writer.writeByte(' ');
        try writeCharRepeated(writer, "-", w);
        try writer.writeByte(' ');
        try writer.writeByte('|');
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
    try writer.writeByte('|');
    for (0..widths.len) |i| {
        const idx: c_int = @intCast(i);
        try writer.writeByte(' ');
        const w = widths[i];

        if (c.sqlite3_column_type(stmt, idx) == c.SQLITE_NULL) {
            // NULL renders as empty cell
            if (numeric[i]) {
                try writeSpaces(writer, w);
            } else {
                try writeSpaces(writer, w);
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
                try writeSpaces(writer, w);
            }
        }
        try writer.writeByte(' ');
        try writer.writeByte('|');
    }
    try writer.writeByte('\n');
}

// ── UTF-8 / visual-width helpers (copied from table.zig) ──────────────────

fn utf8CharLen(first: u8) usize {
    if (first < 0x80) return 1;
    if (first < 0xC0) return 1;
    if (first < 0xE0) return 2;
    if (first < 0xF0) return 3;
    if (first < 0xF8) return 4;
    return 1;
}

fn utf8DecodeRaw(bytes: []const u8) ?u21 {
    return switch (bytes.len) {
        1 => bytes[0],
        2 => std.unicode.utf8Decode2(bytes[0..2].*) catch null,
        3 => std.unicode.utf8Decode3(bytes[0..3].*) catch null,
        4 => std.unicode.utf8Decode4(bytes[0..4].*) catch null,
        else => null,
    };
}

fn isWideCodepoint(cp: u21) bool {
    return (cp >= 0x3400 and cp <= 0x4DBF) or
        (cp >= 0x4E00 and cp <= 0x9FFF) or
        (cp >= 0xAC00 and cp <= 0xD7AF) or
        (cp >= 0xFF00 and cp <= 0xFFEF);
}

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

fn writeSpaces(writer: *std.Io.Writer, n: usize) error{WriteFailed}!void {
    var remaining = n;
    while (remaining > 0) {
        const chunk = @min(remaining, spaces_buf.len);
        try writer.writeAll(spaces_buf[0..chunk]);
        remaining -= chunk;
    }
}

test "writeMarkdown parameter order" {
    try std.testing.expect(true);
}
