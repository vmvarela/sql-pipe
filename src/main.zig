const std = @import("std");
const c = @cImport({
    @cInclude("sqlite3.h");
});
const csv = @import("csv.zig");
const build_options = @import("build_options");

/// Version string injected at build time from build.zig.zon via build.zig.
const VERSION: []const u8 = build_options.version;

// sqlite_static (null): SQLite assumes the memory is constant and won't free it.
// Safety: sqlite3_step is called inside insertRowTyped immediately after all
// bindings, returning SQLITE_DONE before the function returns. The caller's
// row buffer is only freed after insertRowTyped returns, so the bound pointers
// remain valid throughout the statement's execution. sqlite3_reset at the top
// of the next call releases any prior references.
const sqlite_static: c.sqlite3_destructor_type = null;

// ─── Error types ─────────────────────────────────────

const SqlPipeError = error{
    MissingQuery,
    InvalidDelimiter,
    IncompatibleFlags,
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

// ─── Column type inference ────────────────────────────

/// Inferred SQLite affinity for a CSV column.
const ColumnType = enum { TEXT, INTEGER, REAL };

/// Number of rows buffered from stdin to infer column types.
const inference_buffer_size: usize = 100;

/// Structured exit codes for scripting.
///   0 = success
///   1 = usage error (missing query, bad flag)
///   2 = CSV parse error
///   3 = SQL error (sqlite3 error)
const ExitCode = enum(u8) {
    success = 0,
    usage = 1,
    csv_error = 2,
    sql_error = 3,
};

/// Parsed command-line arguments.
const ParsedArgs = struct {
    /// The SQL query to execute after loading stdin.
    query: []const u8,
    /// When false, skip type inference and use TEXT for every column (pure TEXT mode).
    type_inference: bool,
    /// Input field delimiter for CSV parsing.
    delimiter: u8,
    /// When true, print a header row with column names before data rows.
    header: bool,
    /// When true, emit results as a JSON array of objects instead of CSV.
    json: bool,
};

/// Result of argument parsing — either parsed arguments or a special action.
const ArgsResult = union(enum) {
    /// Normal execution: run the query.
    parsed: ParsedArgs,
    /// User requested --help / -h.
    help,
    /// User requested --version / -V.
    version,
};

// ─── Extracted functions ──────────────────────────────

/// printUsage(writer) → void
/// Pre:  writer is a valid stderr writer
/// Post: usage text has been written to writer
fn printUsage(writer: anytype) !void {
    try writer.writeAll(
        \\Usage: sql-pipe [OPTIONS] <query>
        \\
        \\Reads CSV from stdin, loads it into an in-memory SQLite table `t`,
        \\runs <query>, and prints results as CSV to stdout.
        \\
        \\Options:
        \\  -d, --delimiter <char>  Input field delimiter (default: ,)
        \\  --tsv                   Alias for --delimiter '\t'
        \\  --no-type-inference  Treat all columns as TEXT (skip auto-detection)
        \\  -H, --header         Print column names as the first output row
        \\  --json               Output results as a JSON array of objects
        \\  -h, --help           Show this help message and exit
        \\  -V, --version        Show version and exit
        \\
        \\Exit codes:
        \\  0  Success
        \\  1  Usage error (missing query, bad arguments)
        \\  2  CSV parse error
        \\  3  SQL error
        \\
        \\Examples:
        \\  echo 'name,age\nAlice,30' | sql-pipe 'SELECT * FROM t'
        \\  cat data.tsv | sql-pipe --tsv 'SELECT * FROM t'
        \\  cat data.psv | sql-pipe -d '|' 'SELECT * FROM t'
        \\  cat data.csv | sql-pipe 'SELECT region, SUM(revenue) FROM t GROUP BY region'
        \\  cat data.csv | sql-pipe --json 'SELECT * FROM t'
        \\
    );
}

/// parseDelimiter(value) → u8
/// Pre:  value is the delimiter token provided by the user
/// Post: result is a single-byte delimiter, or '\t' when value = "\\t"
///       error.InvalidDelimiter when value is empty or has more than one char
fn parseDelimiter(value: []const u8) SqlPipeError!u8 {
    if (std.mem.eql(u8, value, "\\t")) return '\t';
    if (value.len != 1) return error.InvalidDelimiter;
    return value[0];
}

/// parseArgs(args) → ArgsResult
/// Pre:  args is the full process argument slice; args[0] is the program name
/// Post: result.parsed.query is the first non-flag argument
///       result.parsed.type_inference = false when "--no-type-inference" is present
///       result.parsed.json = true when "--json" is present
///       result = .help when --help or -h is present
///       result = .version when --version or -V is present
///       error.MissingQuery when no non-flag argument is found
///       error.IncompatibleFlags when --json is combined with --delimiter/--tsv/--header
fn parseArgs(args: []const [:0]u8) SqlPipeError!ArgsResult {
    var query: ?[]const u8 = null;
    var type_inference = true;
    var delimiter: u8 = ',';
    var header = false;
    var json = false;
    var explicit_delimiter = false;
    var explicit_tsv = false;

    // Loop invariant I: all args[1..i] have been processed;
    //   query holds the first non-flag argument seen, or null;
    //   type_inference reflects the presence of --no-type-inference;
    //   delimiter reflects -d/--delimiter/--tsv if present;
    //   header reflects the presence of --header/-H;
    //   json reflects the presence of --json
    // Bounding function: args.len - i
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            return .help;
        } else if (std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-V")) {
            return .version;
        } else if (std.mem.eql(u8, arg, "--tsv")) {
            delimiter = '\t';
            explicit_tsv = true;
        } else if (std.mem.eql(u8, arg, "-d") or std.mem.eql(u8, arg, "--delimiter")) {
            i += 1;
            if (i >= args.len) return error.InvalidDelimiter;
            delimiter = try parseDelimiter(args[i]);
            explicit_delimiter = true;
        } else if (std.mem.startsWith(u8, arg, "--delimiter=")) {
            delimiter = try parseDelimiter(arg["--delimiter=".len..]);
            explicit_delimiter = true;
        } else if (std.mem.startsWith(u8, arg, "-d=")) {
            delimiter = try parseDelimiter(arg["-d=".len..]);
            explicit_delimiter = true;
        } else if (std.mem.eql(u8, arg, "--no-type-inference")) {
            type_inference = false;
        } else if (std.mem.eql(u8, arg, "--header") or std.mem.eql(u8, arg, "-H")) {
            header = true;
        } else if (std.mem.eql(u8, arg, "--json")) {
            json = true;
        } else {
            if (query == null) query = arg;
        }
    }

    // --json is mutually exclusive with --delimiter / --tsv / --header
    if (json and (explicit_delimiter or explicit_tsv or header))
        return error.IncompatibleFlags;

    return .{ .parsed = ParsedArgs{
        .query = query orelse return error.MissingQuery,
        .type_inference = type_inference,
        .delimiter = delimiter,
        .header = header,
        .json = json,
    } };
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
/// Note: returns true for integers too; callers should check isInteger first
///       for finer classification.
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
    allocator: std.mem.Allocator,
    buffer: []const [][]u8,
    num_cols: usize,
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
    allocator: std.mem.Allocator,
    record: [][]u8,
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
    allocator: std.mem.Allocator,
    db: *c.sqlite3,
    cols: []const []const u8,
    types: []const ColumnType,
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
        try sql.appendSlice(allocator, switch (types[i]) {
            .INTEGER => " INTEGER",
            .REAL => " REAL",
            .TEXT => " TEXT",
        });
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
    allocator: std.mem.Allocator,
    db: *c.sqlite3,
    n: usize,
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
            if (c.sqlite3_bind_null(stmt, col_idx) != c.SQLITE_OK)
                return error.BindFailed;
        } else switch (col_type) {
            .INTEGER => {
                if (std.fmt.parseInt(i64, val, 10)) |n| {
                    if (c.sqlite3_bind_int64(stmt, col_idx, n) != c.SQLITE_OK)
                        return error.BindFailed;
                } else |_| {
                    // Parse failure: fall back to text binding
                    if (c.sqlite3_bind_text(stmt, col_idx, val.ptr, @intCast(val.len), sqlite_static) != c.SQLITE_OK)
                        return error.BindFailed;
                }
            },
            .REAL => {
                if (std.fmt.parseFloat(f64, val)) |f| {
                    if (c.sqlite3_bind_double(stmt, col_idx, f) != c.SQLITE_OK)
                        return error.BindFailed;
                } else |_| {
                    if (c.sqlite3_bind_text(stmt, col_idx, val.ptr, @intCast(val.len), sqlite_static) != c.SQLITE_OK)
                        return error.BindFailed;
                }
            },
            .TEXT => {
                if (c.sqlite3_bind_text(stmt, col_idx, val.ptr, @intCast(val.len), sqlite_static) != c.SQLITE_OK)
                    return error.BindFailed;
            },
        }
        col_idx += 1;
    }

    // Bind NULL for any trailing columns the row is short of
    // Loop invariant: params 1..col_idx-1 are bound; col_idx..param_count become NULL
    while (col_idx <= param_count) : (col_idx += 1) {
        if (c.sqlite3_bind_null(stmt, col_idx) != c.SQLITE_OK)
            return error.BindFailed;
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

/// writeField(writer, value) → !void
/// Pre:  writer is a valid writer, value is a valid UTF-8 slice
/// Post: value is written to writer as a single CSV field:
///       if value contains comma, double-quote, or newline, it is enclosed
///       in double-quotes with internal quotes escaped as "" (RFC 4180);
///       otherwise it is written verbatim
fn writeField(writer: anytype, value: []const u8) !void {
    var needs_quoting = false;
    for (value) |ch| {
        if (ch == ',' or ch == '"' or ch == '\n' or ch == '\r') {
            needs_quoting = true;
            break;
        }
    }
    if (needs_quoting) {
        try writer.writeByte('"');
        for (value) |ch| {
            if (ch == '"') try writer.writeByte('"');
            try writer.writeByte(ch);
        }
        try writer.writeByte('"');
    } else {
        try writer.writeAll(value);
    }
}

/// printHeaderRow(stmt, col_count, writer) → !void
/// Pre:  stmt is a prepared statement, col_count > 0
/// Post: one CSV line with col_count column names written to writer;
///       names are obtained from sqlite3_column_name (alias or original);
///       fields are RFC 4180 quoted when they contain special characters
fn printHeaderRow(
    stmt: *c.sqlite3_stmt,
    col_count: c_int,
    writer: anytype,
) !void {
    // Loop invariant I: columns 0..i-1 names have been written, separated by commas
    // Bounding function: col_count - i
    var i: c_int = 0;
    while (i < col_count) : (i += 1) {
        if (i > 0) try writer.writeByte(',');
        const name_ptr = c.sqlite3_column_name(stmt, i);
        if (name_ptr != null) {
            const name = std.mem.span(@as([*:0]const u8, @ptrCast(name_ptr)));
            try writeField(writer, name);
        }
    }
    try writer.writeByte('\n');
}

/// writeJsonString(writer, s) → !void
/// Pre:  writer is valid, s is a UTF-8 slice
/// Post: s is written as a JSON string literal (double-quoted, with special
///       characters escaped per RFC 8259: \", \\, \/, \b, \f, \n, \r, \t,
///       and \uXXXX for control characters 0x00–0x1F)
fn writeJsonString(writer: anytype, s: []const u8) !void {
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
/// Pre:  sqlite3_step returned SQLITE_ROW for stmt
///       col_count > 0; col_names.len = col_count
///       is_first indicates whether this is the first row (no leading comma)
/// Post: one JSON object written to writer as { "col": value, … }
///       NULL cells are written as JSON null
///       INTEGER / REAL columns written as JSON numbers
///       TEXT columns written as JSON strings
fn printJsonRow(
    stmt: *c.sqlite3_stmt,
    col_count: c_int,
    col_names: []const [*:0]const u8,
    writer: anytype,
    is_first: bool,
) !void {
    if (!is_first) try writer.writeByte(',');
    try writer.writeByte('{');
    // Loop invariant I: columns 0..i-1 have been written as "name":value pairs
    // Bounding function: col_count - i
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
                // Emit as integer notation when value has no fractional part,
                // otherwise use full precision float.
                if (f == @trunc(f) and !std.math.isInf(f) and !std.math.isNan(f)) {
                    try writer.print("{d}", .{@as(i64, @intFromFloat(f))});
                } else {
                    try writer.print("{d}", .{f});
                }
            },
            else => { // SQLITE_TEXT and SQLITE_BLOB → emit as string
                const ptr = c.sqlite3_column_text(stmt, i);
                if (ptr != null) {
                    try writeJsonString(writer, std.mem.span(@as([*:0]const u8, @ptrCast(ptr))));
                } else {
                    try writer.writeAll("null");
                }
            },
        }
    }
    try writer.writeByte('}');
}

/// execQuery(db, query, allocator, writer, header, json) → !void
/// Pre:  db is open with table `t` populated
///       query is a valid SQL string (not null-terminated)
///       allocator is valid
///       when json = true, header and delimiter flags must not be set (caller's responsibility)
/// Post: if json = true, results are written as a JSON array of objects
///       if header = true (and json = false), column names written as the first CSV row
///       all result rows written to writer as CSV lines via printRow (when json = false)
///       error.PrepareQueryFailed when sqlite3_prepare_v2 returns non-SQLITE_OK
///       propagates any writer I/O error
fn execQuery(
    allocator: std.mem.Allocator,
    db: *c.sqlite3,
    query: []const u8,
    writer: anytype,
    header: bool,
    json: bool,
) (SqlPipeError || std.mem.Allocator.Error || @TypeOf(writer).Error)!void {
    const query_z = try allocator.dupeZ(u8, query);
    defer allocator.free(query_z);

    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(db, query_z.ptr, -1, &stmt, null) != c.SQLITE_OK)
        return error.PrepareQueryFailed;
    defer _ = c.sqlite3_finalize(stmt);

    const col_count = c.sqlite3_column_count(stmt);

    if (json) {
        // Collect column names before stepping (sqlite3_column_name is valid before step)
        var col_names = try allocator.alloc([*:0]const u8, @intCast(col_count));
        defer allocator.free(col_names);
        var ci: c_int = 0;
        while (ci < col_count) : (ci += 1) {
            col_names[@intCast(ci)] = c.sqlite3_column_name(stmt, ci);
        }

        try writer.writeByte('[');
        var first = true;
        // Loop invariant I: all SQLITE_ROW results returned so far have been printed as JSON objects
        // Bounding function: number of remaining rows in the result set (finite)
        while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
            try printJsonRow(stmt.?, col_count, col_names, writer, first);
            first = false;
        }
        try writer.writeAll("]\n");
    } else {
        // When header is requested, print column names before data rows
        if (header and col_count > 0) {
            try printHeaderRow(stmt.?, col_count, writer);
        }

        // Loop invariant I: all SQLITE_ROW results returned so far have been printed
        // Bounding function: number of remaining rows in the result set (finite)
        while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
            try printRow(stmt.?, col_count, writer);
        }
    }
}

// ─── Entry point ──────────────────────────────────────

/// fatal(writer, code, comptime fmt, args) → noreturn
/// Pre:  writer is stderr, code is non-zero ExitCode
/// Post: "error: <message>\n" written to stderr, process exits with code
fn fatal(comptime fmt: []const u8, writer: anytype, code: ExitCode, args: anytype) noreturn {
    writer.print("error: " ++ fmt ++ "\n", args) catch |err| {
        std.log.err("failed to write error message: {}", .{err});
    };
    std.process.exit(@intFromEnum(code));
}

pub fn main() void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const stderr = std.fs.File.stderr();
    const stderr_writer = stderr.deprecatedWriter();
    const stdout_writer = std.fs.File.stdout().deprecatedWriter();

    // {A0: process argv is accessible, allocator is valid}
    const args = std.process.argsAlloc(allocator) catch
        fatal("failed to read process arguments", stderr_writer, .usage, .{});
    defer std.process.argsFree(allocator, args);

    const args_result = parseArgs(args) catch |err| {
        switch (err) {
            error.IncompatibleFlags => {
                stderr_writer.writeAll("error: --json cannot be combined with --delimiter, --tsv, or --header\n") catch |werr| {
                    std.log.err("failed to write error message: {}", .{werr});
                };
                std.process.exit(@intFromEnum(ExitCode.usage));
            },
            else => {},
        }
        printUsage(stderr_writer) catch |werr| {
            std.log.err("failed to write usage: {}", .{werr});
        };
        std.process.exit(@intFromEnum(ExitCode.usage));
    };

    switch (args_result) {
        .help => {
            printUsage(stderr_writer) catch |err| {
                std.log.err("failed to write usage: {}", .{err});
            };
            std.process.exit(@intFromEnum(ExitCode.success));
        },
        .version => {
            stderr_writer.print("sql-pipe {s}\n", .{VERSION}) catch |err| {
                std.log.err("failed to write version: {}", .{err});
            };
            std.process.exit(@intFromEnum(ExitCode.success));
        },
        .parsed => |parsed| {
            run(parsed, allocator, stderr_writer, stdout_writer);
        },
    }
}

/// run(parsed, allocator, stderr_writer, stdout_writer) → void
/// Pre:  parsed contains a valid query; allocator and writers are valid
/// Post: CSV from stdin has been loaded, query executed, results written to stdout
///       On error, an "error: ..." message is written to stderr and process
///       exits with the appropriate ExitCode (1, 2, or 3)
fn run(
    parsed: ParsedArgs,
    allocator: std.mem.Allocator,
    stderr_writer: anytype,
    stdout_writer: anytype,
) void {
    const query = parsed.query;
    // {A1: query is the SQL string; parsed.type_inference indicates buffer-first mode}

    const db = openDb() catch
        fatal("failed to open in-memory database", stderr_writer, .sql_error, .{});
    defer _ = c.sqlite3_close(db);
    // {A2: db is an open, empty in-memory SQLite database}

    const stdin = std.fs.File.stdin().deprecatedReader();
    var csv_reader = csv.csvReaderWithDelimiter(allocator, stdin, parsed.delimiter);

    const header_record = csv_reader.nextRecord() catch |err| switch (err) {
        error.UnterminatedQuotedField => fatal("row 1: unterminated quoted field", stderr_writer, .csv_error, .{}),
        else => fatal("row 1: failed to parse CSV header", stderr_writer, .csv_error, .{}),
    } orelse fatal("empty input (no header row)", stderr_writer, .csv_error, .{});
    defer csv_reader.freeRecord(header_record);

    const cols = parseHeader(allocator, header_record) catch |err| {
        switch (err) {
            error.EmptyColumnName => fatal("row 1: empty column name in header", stderr_writer, .csv_error, .{}),
            error.NoColumns => fatal("row 1: no columns found in header", stderr_writer, .csv_error, .{}),
            else => fatal("row 1: failed to parse header", stderr_writer, .csv_error, .{}),
        }
    };
    defer {
        for (cols) |col| allocator.free(col);
        allocator.free(cols);
    }
    // {A3: cols is a non-empty list of trimmed, BOM-free column names}

    const num_cols = cols.len;

    // ─── Phase 1: determine column types ─────────────────────────────────────
    var row_buffer: std.ArrayList([][]u8) = .{};
    defer {
        for (row_buffer.items) |row| csv_reader.freeRecord(row);
        row_buffer.deinit(allocator);
    }

    var csv_row_count: usize = 1; // 1 = header already read

    const types: []ColumnType = if (parsed.type_inference) blk: {
        while (row_buffer.items.len < inference_buffer_size) {
            const rec = csv_reader.nextRecord() catch |err| switch (err) {
                error.UnterminatedQuotedField => fatal(
                    "row {d}: unterminated quoted field",
                    stderr_writer,
                    .csv_error,
                    .{csv_row_count + 1},
                ),
                else => fatal(
                    "row {d}: failed to parse CSV",
                    stderr_writer,
                    .csv_error,
                    .{csv_row_count + 1},
                ),
            } orelse break;
            csv_row_count += 1;
            if (rec.len == 0) {
                csv_reader.freeRecord(rec);
                continue;
            }
            row_buffer.append(allocator, rec) catch
                fatal("out of memory while buffering rows", stderr_writer, .csv_error, .{});
        }
        break :blk inferTypes(allocator, row_buffer.items, num_cols) catch
            fatal("out of memory during type inference", stderr_writer, .csv_error, .{});
    } else blk: {
        const t = allocator.alloc(ColumnType, num_cols) catch
            fatal("out of memory", stderr_writer, .csv_error, .{});
        @memset(t, .TEXT);
        break :blk t;
    };
    defer allocator.free(types);

    // ─── Phase 2: create table and insert rows ────────────────────────────────

    createTable(allocator, db, cols, types) catch
        fatal("{s}", stderr_writer, .sql_error, .{std.mem.span(c.sqlite3_errmsg(db))});
    // {A5: table `t` exists in db with num_cols columns typed per `types`}

    {
        var errmsg: [*c]u8 = null;
        if (c.sqlite3_exec(db, "BEGIN TRANSACTION", null, null, &errmsg) != c.SQLITE_OK) {
            const msg = if (errmsg != null) std.mem.span(errmsg) else std.mem.span(c.sqlite3_errmsg(db));
            fatal("{s}", stderr_writer, .sql_error, .{msg});
        }
    }
    // {A6: an active transaction is open on db}

    const stmt = prepareInsert(allocator, db, num_cols) catch
        fatal("{s}", stderr_writer, .sql_error, .{std.mem.span(c.sqlite3_errmsg(db))});
    defer _ = c.sqlite3_finalize(stmt);

    // Insert buffered rows
    for (row_buffer.items) |row| {
        insertRowTyped(stmt, db, row, types, @intCast(num_cols)) catch
            fatal("{s}", stderr_writer, .sql_error, .{std.mem.span(c.sqlite3_errmsg(db))});
    }
    // {A7: all buffered rows are in t}

    // Stream remaining rows from stdin
    while (true) {
        const record = csv_reader.nextRecord() catch |err| switch (err) {
            error.UnterminatedQuotedField => fatal(
                "row {d}: unterminated quoted field",
                stderr_writer,
                .csv_error,
                .{csv_row_count + 1},
            ),
            else => fatal(
                "row {d}: failed to parse CSV",
                stderr_writer,
                .csv_error,
                .{csv_row_count + 1},
            ),
        } orelse break;
        csv_row_count += 1;
        defer csv_reader.freeRecord(record);

        if (record.len == 0) continue;

        insertRowTyped(stmt, db, record, types, @intCast(num_cols)) catch
            fatal("{s}", stderr_writer, .sql_error, .{std.mem.span(c.sqlite3_errmsg(db))});
    }
    // {A8: all stdin CSV rows are inserted into t; transaction is still active}

    {
        var errmsg: [*c]u8 = null;
        const rc = c.sqlite3_exec(db, "COMMIT", null, null, &errmsg);
        if (rc != c.SQLITE_OK) {
            const msg = if (errmsg != null) std.mem.span(errmsg) else std.mem.span(c.sqlite3_errmsg(db));
            fatal("{s}", stderr_writer, .sql_error, .{msg});
        }
        if (errmsg != null) c.sqlite3_free(errmsg);
    }
    // {A9: transaction committed; t holds all input rows, no active transaction}

    execQuery(allocator, db, query, stdout_writer, parsed.header, parsed.json) catch |err| {
        switch (err) {
            error.PrepareQueryFailed => {
                fatal("{s}", stderr_writer, .sql_error, .{std.mem.span(c.sqlite3_errmsg(db))});
            },
            else => {
                fatal("{s}", stderr_writer, .sql_error, .{std.mem.span(c.sqlite3_errmsg(db))});
            },
        }
    };
    // {A10: all result rows written to stdout as CSV lines}
}
