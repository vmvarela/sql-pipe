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

// ─── Column type inference ────────────────────────────────────────────────────

/// Inferred SQLite affinity for a CSV column.
const ColumnType = enum { TEXT, INTEGER, REAL };

/// Number of rows buffered from stdin to infer column types.
const INFERENCE_BUFFER_SIZE: usize = 100;

/// Parsed command-line arguments.
const ParsedArgs = struct {
    /// The SQL query to execute after loading stdin.
    query: []const u8,
    /// When false, skip type inference and use TEXT for every column (pure TEXT mode).
    type_inference: bool,
};

// ─── Extracted functions ──────────────────────────────────────────────────────

/// parseArgs(args) → ParsedArgs
/// Pre:  args is the full process argument slice; args[0] is the program name
/// Post: result.query is the first non-flag argument
///       result.type_inference = false when "--no-type-inference" is present
///       error.MissingQuery when no non-flag argument is found
fn parseArgs(args: []const [:0]u8) SqlPipeError!ParsedArgs {
    var query: ?[]const u8 = null;
    var type_inference = true;

    // Loop invariant I: all args[1..i] have been processed;
    //   query holds the first non-flag argument seen, or null;
    //   type_inference reflects the presence of --no-type-inference
    // Bounding function: args.len - i
    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--no-type-inference")) {
            type_inference = false;
        } else {
            if (query == null) query = arg;
        }
    }
    return ParsedArgs{
        .query = query orelse return error.MissingQuery,
        .type_inference = type_inference,
    };
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

/// isInteger(val) → bool
/// Pre:  val is a valid UTF-8 slice
/// Post: result = val matches [+-]?[0-9]+  (non-empty, only digits after optional sign)
fn isInteger(val: []const u8) bool {
    if (val.len == 0) return false;
    var i: usize = 0;
    if (val[0] == '+' or val[0] == '-') i = 1;
    if (i >= val.len) return false; // sign only → not an integer
    // Loop invariant I: val[0..i] is a valid integer prefix (sign + digits)
    // Bounding function: val.len - i
    while (i < val.len) : (i += 1) {
        if (val[i] < '0' or val[i] > '9') return false;
    }
    return true;
}

/// isReal(val) → bool
/// Pre:  val is a valid UTF-8 slice
/// Post: result = val is parseable as a 64-bit floating-point number
///       AND is not an integer (otherwise isInteger should be used)
fn isReal(val: []const u8) bool {
    if (val.len == 0) return false;
    _ = std.fmt.parseFloat(f64, val) catch return false;
    return true;
}

/// inferTypes(buffer, num_cols, allocator) → []ColumnType
/// Pre:  buffer is a slice of rows (each row is a slice of field strings)
///       num_cols > 0; allocator is valid
/// Post: result.len = num_cols
///       result[j] = INTEGER  ⟺  all non-empty values in column j are integers
///       result[j] = REAL     ⟺  all non-empty values are numeric but at least one
///                                is not a plain integer
///       result[j] = TEXT     ⟺  at least one non-empty value is non-numeric,
///                                OR no non-empty values exist
fn inferTypes(
    buffer: []const [][]u8,
    num_cols: usize,
    allocator: std.mem.Allocator,
) std.mem.Allocator.Error![]ColumnType {
    const types = try allocator.alloc(ColumnType, num_cols);
    errdefer allocator.free(types);

    const can_be_integer = try allocator.alloc(bool, num_cols);
    defer allocator.free(can_be_integer);
    const can_be_real = try allocator.alloc(bool, num_cols);
    defer allocator.free(can_be_real);
    const has_data = try allocator.alloc(bool, num_cols);
    defer allocator.free(has_data);

    // Initialise: optimistically assume every column can be INTEGER
    for (0..num_cols) |j| {
        can_be_integer[j] = true;
        can_be_real[j] = true;
        has_data[j] = false;
    }

    // Loop invariant I: for each j in 0..num_cols,
    //   can_be_integer[j] = true  ⟺  all non-empty values in column j seen so far are integers
    //   can_be_real[j]    = true  ⟺  all non-empty values in column j seen so far are numeric
    //   has_data[j]       = true  ⟺  at least one non-empty value has been seen in column j
    // Bounding function: buffer.len - row_idx
    for (buffer) |row| {
        for (row, 0..) |val, j| {
            if (j >= num_cols) break;
            if (val.len == 0) continue; // NULL/empty → skip, does not affect inference
            has_data[j] = true;
            if (!can_be_real[j]) continue; // already TEXT, no need to re-check
            if (!isReal(val)) {
                can_be_real[j] = false;
                can_be_integer[j] = false;
            } else if (!isInteger(val)) {
                can_be_integer[j] = false;
            }
        }
    }

    // Determine final type per column
    // Post: types[j] reflects can_be_integer[j] / can_be_real[j] / has_data[j]
    for (0..num_cols) |j| {
        if (has_data[j] and can_be_integer[j]) {
            types[j] = .INTEGER;
        } else if (has_data[j] and can_be_real[j]) {
            types[j] = .REAL;
        } else {
            types[j] = .TEXT;
        }
    }

    return types;
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
    errdefer {
        for (cols.items) |col| allocator.free(col);
        cols.deinit(allocator);
    }

    // seen: maps a column name to the number of times it has appeared so far.
    // Pre:  seen is empty
    // Post: seen[name] = count of occurrences in record[0..i]
    var seen = std.StringHashMap(usize).init(allocator);
    defer seen.deinit();

    // Loop invariant I: cols contains trimmed, non-empty (possibly suffixed) names for record[0..i]
    //                   seen maps each base name to its occurrence count up to i
    //                   all items in cols are heap-allocated (owned by allocator)
    // Bounding function: record.len - i  (natural, decreasing, lower-bounded by 0)
    for (record) |field| {
        const base = std.mem.trim(u8, field, " \t\r");
        if (base.len == 0) return error.EmptyColumnName;

        const count = (seen.get(base) orelse 0) + 1;
        try seen.put(base, count);

        const col: []const u8 = if (count == 1)
            try allocator.dupe(u8, base)
        else
            try std.fmt.allocPrint(allocator, "{s}_{d}", .{ base, count });

        try cols.append(allocator, col);
    }

    return cols.toOwnedSlice(allocator);
}

/// createTable(db, cols, types, allocator) → void
/// Pre:  db is an open SQLite handle
///       cols.len > 0
///       types.len = cols.len
///       allocator is valid
/// Post: table `t` exists in db with cols.len columns named by cols;
///       each column's SQL type reflects its ColumnType value
///       (INTEGER / REAL / TEXT with correct SQLite affinity)
///       column identifiers are double-quote escaped per SQL syntax
///       error.CreateTableFailed when sqlite3_exec returns non-SQLITE_OK
fn createTable(
    db: *c.sqlite3,
    cols: []const []const u8,
    types: []const ColumnType,
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
        const type_str: []const u8 = if (i < types.len) switch (types[i]) {
            .INTEGER => " INTEGER",
            .REAL => " REAL",
            .TEXT => " TEXT",
        } else " TEXT";
        try sql.appendSlice(allocator, type_str);
    }
    try sql.appendSlice(allocator, ")");
    try sql.append(allocator, 0); // null-terminate for the C API

    var errmsg: [*c]u8 = null;
    if (c.sqlite3_exec(db, sql.items.ptr, null, null, &errmsg) != c.SQLITE_OK) {
        const msg = if (errmsg != null) std.mem.span(errmsg) else std.mem.span(c.sqlite3_errmsg(db));
        std.debug.print("CREATE TABLE failed: {s}\n", .{msg});
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

/// insertRowTyped(stmt, db, row, types, param_count) → void
/// Pre:  stmt is a prepared INSERT with param_count parameters, freshly reset
///       row is a non-empty CSV record (slice of field slices)
///       types.len = param_count (or shorter → remaining treated as TEXT)
///       db is the database that owns stmt (used for error reporting by caller)
/// Post: each field is bound to its parameter using the appropriate SQLite bind
///       function according to types[j]:
///         INTEGER → sqlite3_bind_int64  (fallback: TEXT on parse failure)
///         REAL    → sqlite3_bind_double (fallback: TEXT on parse failure)
///         TEXT    → sqlite3_bind_text
///       empty / missing values → sqlite3_bind_null
///       sqlite3_step returned SQLITE_DONE
///       error.BindFailed / error.StepFailed on SQLite errors
fn insertRowTyped(
    stmt: *c.sqlite3_stmt,
    db: *c.sqlite3,
    row: [][]u8,
    types: []const ColumnType,
    param_count: c_int,
) SqlPipeError!void {
    _ = db;

    _ = c.sqlite3_reset(stmt);
    _ = c.sqlite3_clear_bindings(stmt);

    var col_idx: c_int = 1;

    // Loop invariant I: row[0..col_idx-1] are bound to params 1..col_idx-1
    //                   using the appropriate SQLite bind function for each column type.
    // Bounding function: row.len + 1 - col_idx (decreasing toward 0)
    for (row) |val| {
        if (col_idx > param_count) break;
        const j: usize = @intCast(col_idx - 1);
        const col_type: ColumnType = if (j < types.len) types[j] else .TEXT;

        if (val.len == 0) {
            // Empty / NULL value → bind as SQL NULL regardless of column type
            _ = c.sqlite3_bind_null(stmt, col_idx);
        } else switch (col_type) {
            .INTEGER => {
                if (std.fmt.parseInt(i64, val, 10)) |n| {
                    if (c.sqlite3_bind_int64(stmt, col_idx, n) != c.SQLITE_OK)
                        return error.BindFailed;
                } else |_| {
                    // Parse failure: fall back to text binding
                    if (c.sqlite3_bind_text(stmt, col_idx, val.ptr, @intCast(val.len), SQLITE_STATIC) != c.SQLITE_OK)
                        return error.BindFailed;
                }
            },
            .REAL => {
                if (std.fmt.parseFloat(f64, val)) |f| {
                    if (c.sqlite3_bind_double(stmt, col_idx, f) != c.SQLITE_OK)
                        return error.BindFailed;
                } else |_| {
                    if (c.sqlite3_bind_text(stmt, col_idx, val.ptr, @intCast(val.len), SQLITE_STATIC) != c.SQLITE_OK)
                        return error.BindFailed;
                }
            },
            .TEXT => {
                if (c.sqlite3_bind_text(stmt, col_idx, val.ptr, @intCast(val.len), SQLITE_STATIC) != c.SQLITE_OK)
                    return error.BindFailed;
            },
        }
        col_idx += 1;
    }

    // Bind NULL for any trailing columns the row is short of
    // Loop invariant: params 1..col_idx-1 are bound; col_idx..param_count become NULL
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

    const parsed = parseArgs(args) catch {
        try stderr_writer.writeAll("Usage: sql-pipe [--no-type-inference] <query>\n");
        try stderr_writer.writeAll("Example: echo 'name,age\\nAlice,30' | sql-pipe 'SELECT * FROM t'\n");
        return;
    };
    const query = parsed.query;
    // {A1: query is the SQL string; parsed.type_inference indicates buffer-first mode}

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
    defer {
        for (cols) |col| allocator.free(col);
        allocator.free(cols);
    }
    // {A3: cols is a non-empty list of trimmed, BOM-free column names}

    const num_cols = cols.len;

    // ─── Phase 1: determine column types ─────────────────────────────────────
    //
    // When type_inference = true (default):
    //   Buffer up to INFERENCE_BUFFER_SIZE rows, infer types, then stream the rest.
    // When type_inference = false (--no-type-inference):
    //   Skip buffering; all columns are TEXT.
    //
    // In both branches, `types` owns a heap slice of length num_cols that is
    // freed after the query executes.

    // row_buffer: rows read during the inference phase.
    // Each element is owned by the CSV reader; freed via freeRecord before return.
    var row_buffer: std.ArrayList([][]u8) = .{};
    defer {
        for (row_buffer.items) |row| csv_reader.freeRecord(row);
        row_buffer.deinit(allocator);
    }

    const types: []ColumnType = if (parsed.type_inference) blk: {
        // Buffer up to INFERENCE_BUFFER_SIZE non-empty rows
        // Loop invariant I: row_buffer contains all non-empty rows read so far
        //   AND row_buffer.items.len <= INFERENCE_BUFFER_SIZE
        // Bounding function: INFERENCE_BUFFER_SIZE - row_buffer.items.len
        while (row_buffer.items.len < INFERENCE_BUFFER_SIZE) {
            const rec = (try csv_reader.nextRecord()) orelse break;
            if (rec.len == 0) {
                csv_reader.freeRecord(rec);
                continue;
            }
            try row_buffer.append(allocator, rec);
        }
        // {A4a: row_buffer holds min(N, total_rows) non-empty rows from stdin}

        break :blk try inferTypes(row_buffer.items, num_cols, allocator);
        // {A4b: types[j] is the inferred ColumnType for column j}
    } else blk: {
        // --no-type-inference: allocate and fill with TEXT
        const t = try allocator.alloc(ColumnType, num_cols);
        @memset(t, .TEXT);
        break :blk t;
        // {A4c: types[j] = TEXT for all j}
    };
    defer allocator.free(types);

    // ─── Phase 2: create table and insert rows ────────────────────────────────

    try createTable(db, cols, types, allocator);
    // {A5: table `t` exists in db with num_cols columns typed per `types`}

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
    // {A6: an active transaction is open on db}

    const stmt = try prepareInsert(db, num_cols, allocator);
    defer _ = c.sqlite3_finalize(stmt);
    // {A6': stmt is a prepared INSERT INTO t VALUES (?,…,?) with num_cols params
    //          AND an open transaction is active}

    // Helper: report insert errors uniformly
    const insertWithErrorHandling = struct {
        fn call(
            s: *c.sqlite3_stmt,
            d: *c.sqlite3,
            row: [][]u8,
            ts: []const ColumnType,
            n: c_int,
            ew: anytype,
        ) !bool {
            insertRowTyped(s, d, row, ts, n) catch |err| {
                switch (err) {
                    error.BindFailed => try ew.print("Bind error: {s}\n", .{std.mem.span(c.sqlite3_errmsg(d))}),
                    error.StepFailed => try ew.print("Insert error: {s}\n", .{std.mem.span(c.sqlite3_errmsg(d))}),
                    else => try ew.writeAll("Insert error\n"),
                }
                return false;
            };
            return true;
        }
    }.call;

    // Insert buffered rows (non-empty, already in row_buffer)
    // Loop invariant I: row_buffer[0..i] have been inserted into t
    // Bounding function: row_buffer.items.len - i
    for (row_buffer.items) |row| {
        if (!try insertWithErrorHandling(stmt, db, row, types, @intCast(num_cols), stderr_writer))
            return;
    }
    // {A7: all buffered rows are in t}

    // Stream remaining rows from stdin
    // Loop invariant I: all CSV records read from stdin so far (beyond the buffered ones)
    //                   have been inserted into t
    // Bounding function: number of lines remaining in stdin (finite, decreases by 1 per iteration)
    while (true) {
        const record = (try csv_reader.nextRecord()) orelse break;
        defer csv_reader.freeRecord(record);

        if (record.len == 0) continue;

        if (!try insertWithErrorHandling(stmt, db, record, types, @intCast(num_cols), stderr_writer))
            return;
    }
    // {A8: all stdin CSV rows are inserted into t; transaction is still active}

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
    // {A9: transaction committed; t holds all input rows, no active transaction}

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
    // {A10: all result rows written to stdout as CSV lines}
}
