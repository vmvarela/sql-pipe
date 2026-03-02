const std = @import("std");
const c = @cImport({
    @cInclude("sqlite3.h");
});
const csv = @import("csv.zig");

// SQLITE_STATIC (null): SQLite assumes the memory is constant and won't free it.
// Safe because sqlite3_step is called immediately after binding, before the row
// buffer is freed.
const SQLITE_STATIC: c.sqlite3_destructor_type = null;

// ─── Error types ─────────────────────────────────────────────────────────────

const SqlPipeError = error{
    MissingQuery,
    OpenDbFailed,
    EmptyInput,
    EmptyColumnName,
    NoColumns,
    CreateTableFailed,
    BeginTransactionFailed,
    PrepareInsertFailed,
    BindFailed,
    StepFailed,
    CommitFailed,
    PrepareQueryFailed,
};

// ─── Extracted functions ──────────────────────────────────────────────────────

/// parseArgs(args) → []const u8
/// Pre:  args is the full process argument slice; args[0] is the program name
/// Post: result = args[1], the SQL query string
///       error.MissingQuery when args.len < 2
fn parseArgs(args: []const [:0]u8) SqlPipeError![]const u8 {
    if (args.len < 2) return error.MissingQuery;
    return args[1];
}

/// openDb() → *sqlite3
/// Pre:  —
/// Post: result is an open, empty in-memory SQLite database handle
///       error.OpenDbFailed when sqlite3_open returns non-SQLITE_OK
fn openDb() SqlPipeError!*c.sqlite3 {
    var db: ?*c.sqlite3 = null;
    if (c.sqlite3_open(":memory:", &db) != c.SQLITE_OK) return error.OpenDbFailed;
    return db.?;
}

/// stripQuotes(raw) → []const u8
/// Pre:  raw is a valid UTF-8 slice
/// Post: if raw = '"' ++ inner ++ '"'  =>  result = inner
///       otherwise                     =>  result = raw
/// Note: RFC 4180 quoted-field unescaping is handled by csv.zig; this function
///       provides an explicit, single-location implementation for any residual
///       direct string handling that bypasses the CSV parser.
fn stripQuotes(raw: []const u8) []const u8 {
    if (raw.len >= 2 and raw[0] == '"' and raw[raw.len - 1] == '"')
        return raw[1 .. raw.len - 1];
    return raw;
}

/// parseHeader(record, allocator) → [][]const u8
/// Pre:  record is a non-null CSV record (slice of owned UTF-8 field slices)
///       allocator is valid
/// Post: result is a non-empty slice of trimmed column names (leading/trailing
///       ASCII whitespace removed); UTF-8 BOM stripped from the first field
///       error.EmptyColumnName when any trimmed name is empty
///       error.NoColumns when record is empty
fn parseHeader(
    record: [][]u8,
    allocator: std.mem.Allocator,
) (SqlPipeError || std.mem.Allocator.Error)![][]const u8 {
    if (record.len == 0) return error.NoColumns;

    // Strip UTF-8 BOM (\xEF\xBB\xBF) from first field if present
    const bom = "\xEF\xBB\xBF";
    if (std.mem.startsWith(u8, record[0], bom)) {
        const without_bom = try allocator.dupe(u8, record[0][bom.len..]);
        allocator.free(record[0]);
        record[0] = without_bom;
    }

    var cols: std.ArrayList([]const u8) = .{};
    errdefer cols.deinit(allocator);

    // Loop invariant I: cols contains trimmed, non-empty names for record[0..i]
    // Bounding function: record.len - i  (natural, decreasing, lower-bounded by 0)
    for (record) |field| {
        const col = std.mem.trim(u8, field, " \t\r");
        if (col.len == 0) return error.EmptyColumnName;
        try cols.append(allocator, col);
    }

    return cols.toOwnedSlice(allocator);
}

/// createTable(db, cols, allocator) → void
/// Pre:  db is an open SQLite handle
///       cols.len > 0
///       allocator is valid
/// Post: table `t` exists in db with cols.len TEXT columns named by cols
///       column identifiers are double-quote escaped per SQL syntax
///       error.CreateTableFailed when sqlite3_exec returns non-SQLITE_OK
fn createTable(
    db: *c.sqlite3,
    cols: []const []const u8,
    allocator: std.mem.Allocator,
) (SqlPipeError || std.mem.Allocator.Error)!void {
    var sql: std.ArrayList(u8) = .{};
    defer sql.deinit(allocator);

    try sql.appendSlice(allocator, "CREATE TABLE t (");
    // Loop invariant I: sql = "CREATE TABLE t (" ++ columns[0..i] joined by ", "
    // Bounding function: cols.len - i
    for (cols, 0..) |col, i| {
        if (i > 0) try sql.appendSlice(allocator, ", ");
        try sql.append(allocator, '"');
        // Escape embedded double-quotes by doubling them (SQL identifier rule)
        for (col) |ch| {
            if (ch == '"') try sql.append(allocator, '"');
            try sql.append(allocator, ch);
        }
        try sql.append(allocator, '"');
        try sql.appendSlice(allocator, " TEXT");
    }
    try sql.appendSlice(allocator, ")");
    try sql.append(allocator, 0); // null-terminate for the C API

    var errmsg: [*c]u8 = null;
    if (c.sqlite3_exec(db, sql.items.ptr, null, null, &errmsg) != c.SQLITE_OK) {
        if (errmsg != null) c.sqlite3_free(errmsg);
        return error.CreateTableFailed;
    }
}

/// prepareInsert(db, n, allocator) → *sqlite3_stmt
/// Pre:  db is open, table `t` exists with n TEXT columns, n > 0
///       allocator is valid
/// Post: result is a prepared `INSERT INTO t VALUES (?,…,?)` with n parameters
///       error.PrepareInsertFailed when sqlite3_prepare_v2 returns non-SQLITE_OK
fn prepareInsert(
    db: *c.sqlite3,
    n: usize,
    allocator: std.mem.Allocator,
) (SqlPipeError || std.mem.Allocator.Error)!*c.sqlite3_stmt {
    var sql: std.ArrayList(u8) = .{};
    defer sql.deinit(allocator);

    try sql.appendSlice(allocator, "INSERT INTO t VALUES (");
    for (0..n) |i| {
        if (i > 0) try sql.append(allocator, ',');
        try sql.append(allocator, '?');
    }
    try sql.appendSlice(allocator, ")");
    try sql.append(allocator, 0);

    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(db, sql.items.ptr, -1, &stmt, null) != c.SQLITE_OK)
        return error.PrepareInsertFailed;
    return stmt.?;
}

/// insertRow(stmt, db, row, param_count) → void
/// Pre:  stmt is a prepared INSERT with param_count parameters, freshly reset
///       row is a non-empty CSV record (slice of field slices)
///       db is the database that owns stmt (used for error reporting by caller)
/// Post: row fields are bound to stmt params 1..min(row.len, param_count) and
///       stepped; sqlite3_step returned SQLITE_DONE
///       short rows have trailing NULLs bound for remaining parameters
///       error.BindFailed / error.StepFailed on SQLite errors
fn insertRow(
    stmt: *c.sqlite3_stmt,
    db: *c.sqlite3,
    row: [][]u8,
    param_count: c_int,
) SqlPipeError!void {
    _ = db; // available to callers needing sqlite3_errmsg context

    _ = c.sqlite3_reset(stmt);
    _ = c.sqlite3_clear_bindings(stmt);

    var col_idx: c_int = 1;

    // Loop invariant I: row[0..col_idx-1] are bound to params 1..col_idx-1
    // Bounding function: row.len + 1 - col_idx (decreasing toward 0)
    for (row) |val| {
        if (col_idx > param_count) break;
        if (c.sqlite3_bind_text(stmt, col_idx, val.ptr, @intCast(val.len), SQLITE_STATIC) != c.SQLITE_OK)
            return error.BindFailed;
        col_idx += 1;
    }

    // Bind NULL for any trailing columns the row is short of
    // Loop invariant: params 1..col_idx-1 are bound; col_idx..param_count remain NULL
    while (col_idx <= param_count) : (col_idx += 1) {
        _ = c.sqlite3_bind_null(stmt, col_idx);
    }

    if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.StepFailed;
}

/// printRow(stmt, col_count, writer) → !void
/// Pre:  sqlite3_step returned SQLITE_ROW for stmt
///       col_count = sqlite3_column_count(stmt) > 0
/// Post: one comma-separated CSV line written to writer with col_count values;
///       NULL cells rendered as the literal string "NULL"
fn printRow(
    stmt: *c.sqlite3_stmt,
    col_count: c_int,
    writer: anytype,
) !void {
    // Loop invariant I: columns 0..i-1 have been written, separated by commas
    // Bounding function: col_count - i
    var i: c_int = 0;
    while (i < col_count) : (i += 1) {
        if (i > 0) try writer.writeByte(',');
        if (c.sqlite3_column_type(stmt, i) == c.SQLITE_NULL) {
            try writer.writeAll("NULL");
        } else {
            const ptr = c.sqlite3_column_text(stmt, i);
            if (ptr != null) {
                try writer.writeAll(std.mem.span(@as([*:0]const u8, @ptrCast(ptr))));
            } else {
                try writer.writeAll("NULL");
            }
        }
    }
    try writer.writeByte('\n');
}

/// execQuery(db, query, allocator, writer) → !void
/// Pre:  db is open with table `t` populated
///       query is a valid SQL string (not null-terminated)
///       allocator is valid
/// Post: all result rows written to writer as CSV lines via printRow
///       error.PrepareQueryFailed when sqlite3_prepare_v2 returns non-SQLITE_OK
///       propagates any writer I/O error
fn execQuery(
    db: *c.sqlite3,
    query: []const u8,
    allocator: std.mem.Allocator,
    writer: anytype,
) (SqlPipeError || std.mem.Allocator.Error || @TypeOf(writer).Error)!void {
    const query_z = try allocator.dupeZ(u8, query);
    defer allocator.free(query_z);

    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(db, query_z.ptr, -1, &stmt, null) != c.SQLITE_OK)
        return error.PrepareQueryFailed;
    defer _ = c.sqlite3_finalize(stmt);

    const col_count = c.sqlite3_column_count(stmt);

    // Loop invariant I: all SQLITE_ROW results returned so far have been printed
    // Bounding function: number of remaining rows in the result set (finite)
    while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
        try printRow(stmt.?, col_count, writer);
    }
}

// ─── Entry point ─────────────────────────────────────────────────────────────

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const stderr = std.fs.File.stderr();
    const stderr_writer = stderr.deprecatedWriter();
    const stdout_writer = std.fs.File.stdout().deprecatedWriter();

    // {A0: process argv is accessible, allocator is valid}
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    const query = parseArgs(args) catch {
        try stderr_writer.writeAll("Usage: sql-pipe <query>\n");
        try stderr_writer.writeAll("Example: echo 'name,age\\nAlice,30' | sql-pipe 'SELECT * FROM t'\n");
        return;
    };
    // {A1: query = args[1] is the SQL query string}

    const db = try openDb();
    defer _ = c.sqlite3_close(db);
    // {A2: db is an open, empty in-memory SQLite database}

    const stdin = std.fs.File.stdin().deprecatedReader();
    var csv_reader = csv.csvReader(stdin, allocator);

    const header_record = (try csv_reader.nextRecord()) orelse {
        try stderr_writer.writeAll("Error: empty input\n");
        return;
    };
    defer csv_reader.freeRecord(header_record);

    const cols = parseHeader(header_record, allocator) catch |err| {
        switch (err) {
            error.EmptyColumnName => try stderr_writer.writeAll("Error: empty column name in header\n"),
            error.NoColumns => try stderr_writer.writeAll("Error: no valid column names in header\n"),
            else => try stderr_writer.writeAll("Error: failed to parse header\n"),
        }
        return;
    };
    defer allocator.free(cols);
    // {A3: cols is a non-empty list of trimmed, BOM-free column names}

    const num_cols = cols.len;

    try createTable(db, cols, allocator);
    // {A4: table `t` exists in db with num_cols TEXT columns}

    {
        var errmsg: [*c]u8 = null;
        if (c.sqlite3_exec(db, "BEGIN TRANSACTION", null, null, &errmsg) != c.SQLITE_OK) {
            if (errmsg != null) {
                try stderr_writer.print("BEGIN TRANSACTION failed: {s}\n", .{std.mem.span(errmsg)});
                c.sqlite3_free(errmsg);
            } else {
                try stderr_writer.writeAll("BEGIN TRANSACTION failed\n");
            }
            var rb_errmsg: [*c]u8 = null;
            _ = c.sqlite3_exec(db, "ROLLBACK", null, null, &rb_errmsg);
            if (rb_errmsg != null) c.sqlite3_free(rb_errmsg);
            return;
        }
    }
    // {A5: an active transaction is open on db}

    const stmt = try prepareInsert(db, num_cols, allocator);
    defer _ = c.sqlite3_finalize(stmt);
    // {A5': stmt is a prepared INSERT INTO t VALUES (?,…,?) with num_cols params
    //         AND an open transaction is active}

    // Row-insertion loop
    // Invariant I: all CSV records read so far have been successfully inserted into t
    //              AND stmt is a prepared INSERT with num_cols parameters
    //              AND the open transaction is active
    // Bounding function: number of lines remaining in stdin (finite, decreases by 1 each iteration)
    while (true) {
        const record = (try csv_reader.nextRecord()) orelse break;
        defer csv_reader.freeRecord(record);

        if (record.len == 0) continue;

        insertRow(stmt, db, record, @intCast(num_cols)) catch |err| {
            switch (err) {
                error.BindFailed => {
                    try stderr_writer.print("Bind error: {s}\n", .{std.mem.span(c.sqlite3_errmsg(db))});
                },
                error.StepFailed => {
                    try stderr_writer.print("Insert error: {s}\n", .{std.mem.span(c.sqlite3_errmsg(db))});
                },
                else => try stderr_writer.writeAll("Insert error\n"),
            }
            return;
        };
    }
    // {A6: all stdin CSV rows are inserted into t; transaction is still active}

    {
        var errmsg: [*c]u8 = null;
        const rc = c.sqlite3_exec(db, "COMMIT", null, null, &errmsg);
        if (rc != c.SQLITE_OK) {
            if (errmsg != null) {
                try stderr_writer.print("Commit error: {s}\n", .{std.mem.span(errmsg)});
                c.sqlite3_free(errmsg);
            } else {
                try stderr_writer.print("Commit error: code {d}\n", .{rc});
            }
            return;
        }
        if (errmsg != null) c.sqlite3_free(errmsg);
    }
    // {A7: transaction committed; t holds all input rows, no active transaction}

    execQuery(db, query, allocator, stdout_writer) catch |err| {
        switch (err) {
            error.PrepareQueryFailed => {
                try stderr_writer.print("Query prepare error: {s}\n", .{std.mem.span(c.sqlite3_errmsg(db))});
            },
            else => {
                try stderr_writer.print("Query error: {s}\n", .{std.mem.span(c.sqlite3_errmsg(db))});
            },
        }
        return;
    };
    // {A8: all result rows written to stdout as CSV lines}
}
