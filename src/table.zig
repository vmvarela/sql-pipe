//! Pretty-printed table output with box-drawing characters.
//!
//! Buffers all result rows, computes column widths, detects numeric columns
//! for right-alignment, and prints a formatted table with Unicode borders.
//!
//! Used when stdout is a TTY (auto-detected) or when --table is passed.

const std = @import("std");
const c = @import("c");

/// Write a formatted table from SQLite query results to the given writer.
///
/// Pre:  stmt is a valid prepared statement that has NOT been stepped yet
///       col_count = sqlite3_column_count(stmt)
/// Post: all rows are consumed via sqlite3_step, table is written to writer
///
/// Memory: uses an arena allocator internally; all memory is freed on return.
pub fn writeTable(
    allocator: std.mem.Allocator,
    stmt: *c.sqlite3_stmt,
    col_count: c_int,
    writer: *std.Io.Writer,
) (std.mem.Allocator.Error || error{WriteFailed})!void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const ncols: usize = @intCast(col_count);
    if (ncols == 0) return;

    // 1. Collect column names (duped for safety)
    const col_names = try a.alloc([]const u8, ncols);
    for (0..ncols) |i| {
        const name_ptr = c.sqlite3_column_name(stmt, @intCast(i));
        if (name_ptr != null) {
            col_names[i] = try a.dupe(u8, std.mem.span(@as([*:0]const u8, @ptrCast(name_ptr))));
        } else {
            col_names[i] = "";
        }
    }

    // 2. Buffer all rows as string slices (must dupe — SQLite invalidates column text on next step)
    var rows = std.ArrayList([]const []const u8).empty;
    defer rows.deinit(a);

    while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
        const row = try a.alloc([]const u8, ncols);
        for (0..ncols) |i| {
            const idx: c_int = @intCast(i);
            if (c.sqlite3_column_type(stmt, idx) == c.SQLITE_NULL) {
                row[i] = "";
            } else {
                const ptr = c.sqlite3_column_text(stmt, idx);
                if (ptr != null) {
                    row[i] = try a.dupe(u8, std.mem.span(@as([*:0]const u8, @ptrCast(ptr))));
                } else {
                    row[i] = "";
                }
            }
        }
        try rows.append(a, row);
    }

    // 3. Compute column widths (max of header and all values)
    const widths = try a.alloc(usize, ncols);
    for (0..ncols) |i| {
        widths[i] = col_names[i].len;
        for (rows.items) |row| {
            if (row[i].len > widths[i]) widths[i] = row[i].len;
        }
        // Minimum width of 1 to avoid zero-width columns
        if (widths[i] == 0) widths[i] = 1;
    }

    // 4. Detect numeric columns for right-alignment
    const numeric = try a.alloc(bool, ncols);
    for (0..ncols) |i| {
        numeric[i] = isColumnNumeric(rows.items, i);
    }

    // 5. Print the table
    // Top border: ┌─────────┬───────────┐
    try writeBorder(writer, widths, .top);

    // Header row: │ region  │ total     │
    try writeRow(writer, col_names, widths, numeric, .header);

    // Header separator: ├─────────┼───────────┤
    try writeBorder(writer, widths, .middle);

    // Data rows: │ AMER    │ 203100.75 │
    for (rows.items) |row| {
        try writeRow(writer, row, widths, numeric, .data);
    }

    // Bottom border: └─────────┴───────────┘
    try writeBorder(writer, widths, .bottom);
}

const BorderPosition = enum { top, middle, bottom };
const RowKind = enum { header, data };

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
        // Each column segment: ─ repeated (width + 2) times (for space padding)
        var j: usize = 0;
        while (j < w + 2) : (j += 1) {
            try writer.writeAll("─");
        }
        if (i < widths.len - 1) {
            try writer.writeAll(cross);
        }
    }
    try writer.writeAll(right);
    try writer.writeByte('\n');
}

/// Write a data or header row with proper alignment.
fn writeRow(
    writer: *std.Io.Writer,
    values: []const []const u8,
    widths: []const usize,
    numeric: []const bool,
    kind: RowKind,
) error{WriteFailed}!void {
    try writer.writeAll("│");
    for (values, 0..) |val, i| {
        try writer.writeByte(' ');
        const w = widths[i];
        const padding = w - val.len;

        switch (kind) {
            .header => {
                // Headers are always left-aligned
                try writer.writeAll(val);
                try writeSpaces(writer, padding);
            },
            .data => {
                if (val.len == 0) {
                    // Empty/NULL values: leave blank
                    try writeSpaces(writer, w);
                } else if (numeric[i]) {
                    // Right-align numeric values
                    try writeSpaces(writer, padding);
                    try writer.writeAll(val);
                } else {
                    // Left-align text values
                    try writer.writeAll(val);
                    try writeSpaces(writer, padding);
                }
            },
        }
        try writer.writeByte(' ');
        try writer.writeAll("│");
    }
    try writer.writeByte('\n');
}

/// Write n space characters.
fn writeSpaces(writer: *std.Io.Writer, n: usize) error{WriteFailed}!void {
    var i: usize = 0;
    while (i < n) : (i += 1) {
        try writer.writeByte(' ');
    }
}

/// Check if all non-empty values in a column are numeric (integer or float).
/// Returns true only if at least one value is non-empty and all parse as numbers.
fn isColumnNumeric(rows: []const []const []const u8, col_idx: usize) bool {
    var has_value = false;
    for (rows) |row| {
        const val = row[col_idx];
        if (val.len == 0) continue; // skip empty/NULL
        has_value = true;
        if (!isNumericString(val)) return false;
    }
    return has_value;
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
