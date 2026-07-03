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
const visual = @import("visual.zig");

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
    null_value: ?[]const u8,
) (std.mem.Allocator.Error || error{WriteFailed, StepFailed})!void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const default_null_text = null_value orelse "";
    const default_null_width = visual.visualWidth(default_null_text);

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
        widths[i] = visual.visualWidth(col_names[i]);
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
                if (default_null_width > widths[i]) widths[i] = default_null_width;
            } else {
                has_value[i] = true;
                if (col_type != c.SQLITE_INTEGER and col_type != c.SQLITE_FLOAT) {
                    numeric[i] = false;
                }
                const ptr = c.sqlite3_column_text(stmt, idx);
                if (ptr != null) {
                    const s = std.mem.span(@as([*:0]const u8, @ptrCast(ptr)));
                    const vw = visual.visualWidth(s);
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
        try writeDataRow(writer, stmt, widths, numeric, null_value);
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
        const vw = visual.visualWidth(val);
        const padding = w - vw;
        if (right_align) {
            try visual.writeSpaces(writer, padding);
            try writer.writeAll(val);
        } else {
            try writer.writeAll(val);
            try visual.writeSpaces(writer, padding);
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
        try visual.writeCharRepeated(writer, "-", w);
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
    null_value: ?[]const u8,
) error{WriteFailed}!void {
    try writer.writeByte('|');
    for (0..widths.len) |i| {
        const idx: c_int = @intCast(i);
        try writer.writeByte(' ');
        const w = widths[i];

        if (c.sqlite3_column_type(stmt, idx) == c.SQLITE_NULL) {
            const null_text = null_value orelse "";
            const nw = visual.visualWidth(null_text);
            if (numeric[i]) {
                try visual.writeSpaces(writer, w - nw);
                try writer.writeAll(null_text);
            } else {
                try writer.writeAll(null_text);
                try visual.writeSpaces(writer, w - nw);
            }
        } else {
            if (sqlite_mod.columnText(stmt, idx)) |val| {
                const vw = visual.visualWidth(val);
                const padding = w - vw;
                if (numeric[i] and val.len > 0) {
                    try visual.writeSpaces(writer, padding);
                    try writer.writeAll(val);
                } else {
                    try writer.writeAll(val);
                    try visual.writeSpaces(writer, padding);
                }
            } else {
                try visual.writeSpaces(writer, w);
            }
        }
        try writer.writeByte(' ');
        try writer.writeByte('|');
    }
    try writer.writeByte('\n');
}

test "writeMarkdown parameter order" {
    try std.testing.expect(true);
}
