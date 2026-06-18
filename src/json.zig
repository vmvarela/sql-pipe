//! JSON and NDJSON I/O — input loading and output formatting.
//!
//! Input
//! ─────
//!   loadJsonArray    — read all of `reader` as a JSON array of objects,
//!                      create table `t` in `db`, and insert every row.
//!   loadNdjsonInput  — stream `reader` line-by-line as NDJSON objects,
//!                      create table `t` in `db`, and insert every row.
//!
//! Output
//! ──────
//!   writeJsonString  — emit a JSON string literal with RFC 8259 escaping.
//!   printJsonRow     — emit one SQLite result row as a JSON object.
//!   printNdjsonRow   — emit one SQLite result row as an NDJSON line.
//!
//! Shared helpers
//! ──────────────
//!   bindJsonValue      — bind a std.json.Value to a prepared-statement parameter.
//!   insertRowFromJson  — bind all fields of a JSON object and step the statement.
//!   readLine           — read one line from a reader (also used by runColumns in main).

const std = @import("std");
const c = @import("c");

const sqlite_helpers = @import("sqlite.zig");

const createAllTextTable = sqlite_helpers.createAllTextTable;
const prepareInsertStmt = sqlite_helpers.prepareInsertStmt;
const beginTransaction = sqlite_helpers.beginTransaction;
const commitTransaction = sqlite_helpers.commitTransaction;
const fatal = sqlite_helpers.fatal;
const ExitCode = sqlite_helpers.ExitCode;
const sqlite_static = sqlite_helpers.sqlite_static;

// ─── Shared helpers ───────────────────────────────────

/// Read one line from reader, stripping the line terminator (LF and optional preceding CR).
///
/// Pre:  reader is positioned at the start of the next line (or EOF)
/// Post: result = null  ⟺  reader was at EOF before any bytes were read
///       result = line  ⟺  bytes up to (but not including) the next '\n' are returned;
///                         trailing '\r' before the '\n' is stripped; heap-allocated
pub fn readLine(
    allocator: std.mem.Allocator,
    reader: *std.Io.Reader,
) (std.mem.Allocator.Error || error{ReadFailed})!?[]u8 {
    var line: std.ArrayList(u8) = .empty;
    errdefer line.deinit(allocator);
    var got_any = false;
    while (true) {
        const byte = reader.takeByte() catch |err| switch (err) {
            error.EndOfStream => {
                if (!got_any) {
                    line.deinit(allocator);
                    return null;
                }
                break;
            },
            error.ReadFailed => return error.ReadFailed,
        };
        got_any = true;
        if (byte == '\n') break;
        try line.append(allocator, byte);
    }
    // Strip trailing \r for \r\n line endings
    if (line.items.len > 0 and line.items[line.items.len - 1] == '\r') {
        line.items.len -= 1;
    }
    const result = try line.toOwnedSlice(allocator);
    return result;
}

/// bindJsonValue(allocator, stmt, col_idx, value, deferred_allocs) → void
///
/// Pre:  stmt is a prepared statement; col_idx ≥ 1
///       deferred_allocs collects allocations that must outlive sqlite3_step
/// Post: value is bound to parameter col_idx:
///         .null           → sqlite3_bind_null
///         .bool           → sqlite3_bind_int64  (1 / 0)
///         .integer        → sqlite3_bind_int64
///         .float          → sqlite3_bind_double
///         .number_string  → sqlite3_bind_text  (STATIC; arena owns the string)
///         .string         → sqlite3_bind_text  (STATIC; arena owns the string)
///         .array/.object  → sqlite3_bind_text  (JSON-serialised; owned by deferred_allocs)
///       error.BindFailed on any sqlite3_bind_* failure
pub fn bindJsonValue(
    allocator: std.mem.Allocator,
    stmt: *c.sqlite3_stmt,
    col_idx: c_int,
    value: std.json.Value,
    deferred_allocs: *std.ArrayList([]u8),
) (error{BindFailed} || std.mem.Allocator.Error)!void {
    switch (value) {
        .null => {
            if (c.sqlite3_bind_null(stmt, col_idx) != c.SQLITE_OK) return error.BindFailed;
        },
        .bool => |b| {
            if (c.sqlite3_bind_int64(stmt, col_idx, if (b) 1 else 0) != c.SQLITE_OK) return error.BindFailed;
        },
        .integer => |n| {
            if (c.sqlite3_bind_int64(stmt, col_idx, n) != c.SQLITE_OK) return error.BindFailed;
        },
        .float => |f| {
            if (c.sqlite3_bind_double(stmt, col_idx, f) != c.SQLITE_OK) return error.BindFailed;
        },
        .number_string => |s| {
            if (c.sqlite3_bind_text(stmt, col_idx, s.ptr, @intCast(s.len), sqlite_static) != c.SQLITE_OK)
                return error.BindFailed;
        },
        .string => |s| {
            if (c.sqlite3_bind_text(stmt, col_idx, s.ptr, @intCast(s.len), sqlite_static) != c.SQLITE_OK)
                return error.BindFailed;
        },
        .array, .object => {
            // Serialise to JSON text; defer free must happen AFTER sqlite3_step, so we
            // hand the allocation to the caller via deferred_allocs.
            const serialized = try std.fmt.allocPrint(allocator, "{f}", .{std.json.fmt(value, .{})});
            try deferred_allocs.append(allocator, serialized);
            if (c.sqlite3_bind_text(stmt, col_idx, serialized.ptr, @intCast(serialized.len), sqlite_static) != c.SQLITE_OK)
                return error.BindFailed;
        },
    }
}

/// insertRowFromJson(allocator, stmt, cols, obj) → void
///
/// Pre:  stmt is a prepared INSERT with cols.len parameters, ready for reset
///       cols is the ordered list of column names used to look up values in obj
///       obj is a JSON object
/// Post: each column in cols is bound to the corresponding value in obj
///       (SQL NULL when the key is absent); sqlite3_step returned SQLITE_DONE
///       error.BindFailed / error.StepFailed on SQLite errors
pub fn insertRowFromJson(
    allocator: std.mem.Allocator,
    stmt: *c.sqlite3_stmt,
    cols: []const []const u8,
    obj: std.json.ObjectMap,
) (error{ BindFailed, StepFailed } || std.mem.Allocator.Error)!void {
    _ = c.sqlite3_reset(stmt);
    _ = c.sqlite3_clear_bindings(stmt);

    // Collect serialized array/object strings so they outlive sqlite3_step.
    var deferred_allocs: std.ArrayList([]u8) = .empty;
    defer {
        for (deferred_allocs.items) |s| allocator.free(s);
        deferred_allocs.deinit(allocator);
    }

    for (cols, 0..) |col, j| {
        const col_idx: c_int = @intCast(j + 1);
        if (obj.get(col)) |val| {
            try bindJsonValue(allocator, stmt, col_idx, val, &deferred_allocs);
        } else {
            if (c.sqlite3_bind_null(stmt, col_idx) != c.SQLITE_OK) return error.BindFailed;
        }
    }

    if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.StepFailed;
}

/// navigateJsonPath(value, path, stderr_writer) → std.json.Value
///
/// Pre:  value is a parsed JSON value; path is a non-empty dot-separated key sequence
/// Post: returns the JSON value at the given path
///       fatals if any segment is empty, not found, or if an intermediate value is not an object
pub fn navigateJsonPath(
    value: std.json.Value,
    path: []const u8,
    stderr_writer: *std.Io.Writer,
) std.json.Value {
    var current = value;
    var remaining = path;
    while (remaining.len > 0) {
        const dot = std.mem.indexOfScalar(u8, remaining, '.') orelse remaining.len;
        const key = remaining[0..dot];
        remaining = if (dot < remaining.len) remaining[dot + 1 ..] else &.{};
        if (key.len == 0)
            fatal("--json-path '{s}': empty key segment (check for double dots or leading/trailing dots)", stderr_writer, .csv_error, .{path});
        const obj = switch (current) {
            .object => |o| o,
            else => fatal("--json-path '{s}': '{s}' is not an object", stderr_writer, .csv_error, .{ path, key }),
        };
        current = obj.get(key) orelse
            fatal("--json-path '{s}': key '{s}' not found in JSON document", stderr_writer, .csv_error, .{ path, key });
    }
    return current;
}

/// Result of firstJsonObject, providing both the resolved array and its first object.
pub const FirstJsonResult = struct {
    array: std.json.Array,
    first_obj: ?std.json.ObjectMap,
};

/// Navigate a parsed JSON value to the target array and return the array and its first object.
/// Returns `first_obj = null` for empty arrays. Fatals if the path doesn't resolve to an array of objects.
pub fn firstJsonObject(
    parsed_value: std.json.Value,
    json_path: ?[]const u8,
    stderr_writer: *std.Io.Writer,
) FirstJsonResult {
    const target: std.json.Value = if (json_path) |path|
        navigateJsonPath(parsed_value, path, stderr_writer)
    else
        parsed_value;

    const array = switch (target) {
        .array => |a| a,
        else => if (json_path) |path|
            fatal("--json-path '{s}': resolved to a non-array value; expected an array of objects", stderr_writer, .csv_error, .{path})
        else
            fatal("JSON input must be an array of objects", stderr_writer, .csv_error, .{}),
    };
    if (array.items.len == 0) return .{ .array = array, .first_obj = null };

    const first_obj = switch (array.items[0]) {
        .object => |o| o,
        else => fatal("JSON array elements must be objects", stderr_writer, .csv_error, .{}),
    };
    return .{ .array = array, .first_obj = first_obj };
}

// ─── Input loading ────────────────────────────────────

/// loadJsonArray(allocator, reader, db, table_name, max_rows, json_path, stderr_writer) → usize
///
/// Pre:  reader is positioned at the start of a JSON document
///       db is an open, empty SQLite database
/// Post: table is created with TEXT columns derived from the first object's keys;
///       all elements of the JSON array are inserted as rows
///       result = number of rows inserted
///       aborts the process on any parse, I/O, or SQL error
pub fn loadJsonArray(
    allocator: std.mem.Allocator,
    reader: *std.Io.Reader,
    db: *c.sqlite3,
    table_name: []const u8,
    max_rows: ?usize,
    json_path: ?[]const u8,
    stderr_writer: *std.Io.Writer,
) usize {
    // Read all input into a buffer using block reads instead of byte-by-byte takeByte()
    const buf = sqlite_helpers.readAllInput(reader, allocator, stderr_writer, "JSON input");
    defer allocator.free(buf);

    if (buf.len == 0) return 0; // Empty input - return 0 rows gracefully

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, buf, .{}) catch
        fatal("failed to parse JSON input", stderr_writer, .csv_error, .{});
    defer parsed.deinit();

    const fj = firstJsonObject(parsed.value, json_path, stderr_writer);
    const first_obj = fj.first_obj orelse return 0; // Empty array - return 0 rows gracefully
    const array = fj.array;

    var cols: std.ArrayList([]const u8) = .empty;
    defer cols.deinit(allocator);
    var key_iter = first_obj.iterator();
    while (key_iter.next()) |entry| {
        cols.append(allocator, entry.key_ptr.*) catch
            fatal("out of memory building column list", stderr_writer, .csv_error, .{});
    }
    if (cols.items.len == 0) fatal("first JSON object has no keys", stderr_writer, .csv_error, .{});

    // Create all-TEXT table (column names are owned by parsed arena — valid until parsed.deinit())
    createAllTextTable(allocator, db, table_name, cols.items, stderr_writer);
    beginTransaction(db, stderr_writer);

    const stmt = prepareInsertStmt(allocator, db, table_name, cols.items.len, stderr_writer);
    defer _ = c.sqlite3_finalize(stmt);

    var rows_inserted: usize = 0;
    for (array.items) |item| {
        const obj = switch (item) {
            .object => |o| o,
            else => fatal("JSON array element is not an object", stderr_writer, .csv_error, .{}),
        };
        rows_inserted += 1;
        sqlite_helpers.checkMaxRows(rows_inserted, max_rows, stderr_writer);
        insertRowFromJson(allocator, stmt, cols.items, obj) catch
            fatal("{s}", stderr_writer, .sql_error, .{std.mem.span(c.sqlite3_errmsg(db))});
    }

    commitTransaction(db, stderr_writer);
    return rows_inserted;
}

/// loadNdjsonInput(allocator, reader, db, table_name, max_rows, stderr_writer) → usize
///
/// Pre:  reader is positioned at the start of a newline-delimited JSON stream
///       db is an open, empty SQLite database
/// Post: table is created with TEXT columns from the first non-blank line;
///       every non-blank line is parsed as a JSON object and inserted as a row
///       result = number of rows inserted
///       aborts the process on any parse, I/O, or SQL error
pub fn loadNdjsonInput(
    allocator: std.mem.Allocator,
    reader: *std.Io.Reader,
    db: *c.sqlite3,
    table_name: []const u8,
    max_rows: ?usize,
    stderr_writer: *std.Io.Writer,
) usize {
    var line_num: usize = 0;
    // cols_owned: column names duplicated into allocator; populated on first object
    var cols_owned: ?[][]u8 = null;
    defer if (cols_owned) |cs| {
        for (cs) |col| allocator.free(col);
        allocator.free(cs);
    };
    var insert_stmt: ?*c.sqlite3_stmt = null;
    defer if (insert_stmt) |s| { _ = c.sqlite3_finalize(s); };
    var rows_inserted: usize = 0;
    var in_transaction = false;

    while (true) {
        line_num += 1;
        const line = readLine(allocator, reader) catch |err| switch (err) {
            error.OutOfMemory => fatal("out of memory reading NDJSON", stderr_writer, .csv_error, .{}),
            error.ReadFailed => fatal("line {d}: failed to read NDJSON input", stderr_writer, .csv_error, .{line_num}),
        } orelse break;
        defer allocator.free(line);

        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) {
            line_num -= 1;
            continue; // skip blank lines
        }

        var parsed_line = std.json.parseFromSlice(std.json.Value, allocator, trimmed, .{}) catch
            fatal("line {d}: failed to parse NDJSON", stderr_writer, .csv_error, .{line_num});
        defer parsed_line.deinit();

        const obj = switch (parsed_line.value) {
            .object => |o| o,
            else => fatal("line {d}: NDJSON element must be a JSON object", stderr_writer, .csv_error, .{line_num}),
        };

        if (cols_owned == null) {
            // First object: extract column names and create table
            var col_list: std.ArrayList([]u8) = .empty;
            errdefer {
                for (col_list.items) |col| allocator.free(col);
                col_list.deinit(allocator);
            }
            var ki = obj.iterator();
            while (ki.next()) |entry| {
                const owned_key = allocator.dupe(u8, entry.key_ptr.*) catch
                    fatal("out of memory building column list", stderr_writer, .csv_error, .{});
                col_list.append(allocator, owned_key) catch
                    fatal("out of memory building column list", stderr_writer, .csv_error, .{});
            }
            if (col_list.items.len == 0)
                fatal("line 1: first NDJSON object has no keys", stderr_writer, .csv_error, .{});

            cols_owned = col_list.toOwnedSlice(allocator) catch
                fatal("out of memory", stderr_writer, .csv_error, .{});

            const cols_const: []const []const u8 = @ptrCast(cols_owned.?);
            createAllTextTable(allocator, db, table_name, cols_const, stderr_writer);
            beginTransaction(db, stderr_writer);
            in_transaction = true;

            insert_stmt = prepareInsertStmt(allocator, db, table_name, cols_owned.?.len, stderr_writer);
        }

        rows_inserted += 1;
        sqlite_helpers.checkMaxRows(rows_inserted, max_rows, stderr_writer);

        const cols_const: []const []const u8 = @ptrCast(cols_owned.?);
        insertRowFromJson(allocator, insert_stmt.?, cols_const, obj) catch
            fatal("line {d}: {s}", stderr_writer, .sql_error, .{ line_num, std.mem.span(c.sqlite3_errmsg(db)) });
    }

    if (cols_owned == null)
        return 0; // Empty NDJSON input - return 0 rows gracefully

    if (in_transaction) commitTransaction(db, stderr_writer);
    return rows_inserted;
}

// ─── Output formatting ────────────────────────────────

/// writeJsonString(writer, s) → !void
///
/// Pre:  s is a valid UTF-8 slice
/// Post: s is emitted to writer as a JSON string literal enclosed in double-quotes,
///       with all RFC 8259–required characters escaped
pub fn writeJsonString(writer: *std.Io.Writer, s: []const u8) !void {
    try writer.writeByte('"');
    for (s) |ch| {
        switch (ch) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '/' => try writer.writeAll("\\/"),
            '\x08' => try writer.writeAll("\\b"),
            '\x0C' => try writer.writeAll("\\f"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            0x00...0x07, 0x0B, 0x0E...0x1F => try writer.print("\\u{x:0>4}", .{ch}),
            else => try writer.writeByte(ch),
        }
    }
    try writer.writeByte('"');
}

/// printJsonRow(stmt, col_count, col_names, writer, is_first) → !void
///
/// Pre:  sqlite3_step returned SQLITE_ROW for stmt
///       col_count = sqlite3_column_count(stmt) > 0
///       col_names.len ≥ col_count
/// Post: one JSON object written to writer representing the current row;
///       preceded by a ',' separator when is_first = false
pub fn printJsonRow(
    stmt: *c.sqlite3_stmt,
    col_count: c_int,
    col_names: []const [*:0]const u8,
    writer: *std.Io.Writer,
    is_first: bool,
) !void {
    if (!is_first) try writer.writeByte(',');
    try writer.writeByte('{');
    var i: c_int = 0;
    while (i < col_count) : (i += 1) {
        if (i > 0) try writer.writeByte(',');
        const name = std.mem.span(col_names[@intCast(i)]);
        try writeJsonString(writer, name);
        try writer.writeByte(':');
        switch (c.sqlite3_column_type(stmt, i)) {
            c.SQLITE_NULL => try writer.writeAll("null"),
            c.SQLITE_INTEGER => try writer.print("{d}", .{c.sqlite3_column_int64(stmt, i)}),
            c.SQLITE_FLOAT => {
                const f = c.sqlite3_column_double(stmt, i);
                if (f == @trunc(f) and !std.math.isInf(f) and !std.math.isNan(f)) {
                    try writer.print("{d}", .{@as(i64, @intFromFloat(f))});
                } else {
                    try writer.print("{d}", .{f});
                }
            },
            else => {
                if (sqlite_helpers.columnText(stmt, i)) |text| {
                    try writeJsonString(writer, text);
                } else {
                    try writer.writeAll("null");
                }
            },
        }
    }
    try writer.writeByte('}');
}

/// printNdjsonRow(stmt, col_count, col_names, writer) → !void
///
/// Pre:  sqlite3_step returned SQLITE_ROW for stmt
///       col_count > 0; col_names.len ≥ col_count
/// Post: one JSON object followed by '\n' written to writer
pub fn printNdjsonRow(
    stmt: *c.sqlite3_stmt,
    col_count: c_int,
    col_names: []const [*:0]const u8,
    writer: *std.Io.Writer,
) !void {
    try writer.writeByte('{');
    var i: c_int = 0;
    while (i < col_count) : (i += 1) {
        if (i > 0) try writer.writeByte(',');
        const name = std.mem.span(col_names[@intCast(i)]);
        try writeJsonString(writer, name);
        try writer.writeByte(':');
        switch (c.sqlite3_column_type(stmt, i)) {
            c.SQLITE_NULL => try writer.writeAll("null"),
            c.SQLITE_INTEGER => try writer.print("{d}", .{c.sqlite3_column_int64(stmt, i)}),
            c.SQLITE_FLOAT => {
                const f = c.sqlite3_column_double(stmt, i);
                if (f == @trunc(f) and !std.math.isInf(f) and !std.math.isNan(f)) {
                    try writer.print("{d}", .{@as(i64, @intFromFloat(f))});
                } else {
                    try writer.print("{d}", .{f});
                }
            },
            else => {
                if (sqlite_helpers.columnText(stmt, i)) |text| {
                    try writeJsonString(writer, text);
                } else {
                    try writer.writeAll("null");
                }
            },
        }
    }
    try writer.writeAll("}\n");
}
