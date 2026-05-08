const std = @import("std");
const c = @import("c");
const csv = @import("csv.zig");
const json = @import("json.zig");
const xml = @import("xml.zig");
const format = @import("format.zig");
const build_options = @import("build_options");
const args_mod = @import("args.zig");
const sqlite_mod = @import("sqlite.zig");
const ColumnType = sqlite_mod.ColumnType;
const sqlite_static = sqlite_mod.sqlite_static;

const VERSION: []const u8 = build_options.version;

const SqlPipeError = args_mod.SqlPipeError;
const ParsedArgs = args_mod.ParsedArgs;
const ColumnsArgs = args_mod.ColumnsArgs;
const ValidateArgs = args_mod.ValidateArgs;
const SampleArgs = args_mod.SampleArgs;
const ArgsResult = args_mod.ArgsResult;
const parseArgs = args_mod.parseArgs;
const printUsage = args_mod.printUsage;

// ─── Column type inference ────────────────────────────

/// Number of rows buffered from stdin to infer column types.
const inference_buffer_size: usize = 100;

/// Number of rows between progress indicator updates.
const progress_interval: usize = 10_000;

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

/// Supported input formats (canonical definition lives in format.zig).
const InputFormat = format.InputFormat;

/// Supported output formats (canonical definition lives in format.zig).
const OutputFormat = format.OutputFormat;

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

/// parseHeader(record, allocator, stderr_writer) → [][]const u8
/// Pre:  record is a non-null CSV record (slice of owned UTF-8 field slices)
///       allocator is valid
///       stderr_writer is a valid writer (warnings are best-effort; write errors ignored)
/// Post: result is a non-empty slice of trimmed column names (leading/trailing
///       ASCII whitespace removed); UTF-8 BOM stripped from the first field
///       duplicate names are suffixed (_2, _3, …) and a warning is written to
///       stderr for each rename: `warning: duplicate column "<original>" renamed to "<new>"`
///       error.EmptyColumnName when any trimmed name is empty
///       error.NoColumns when record is empty
fn parseHeader(
    allocator: std.mem.Allocator,
    record: [][]u8,
    stderr_writer: *std.Io.Writer,
) (SqlPipeError || std.mem.Allocator.Error)![][]const u8 {
    if (record.len == 0) return error.NoColumns;

    // Strip UTF-8 BOM (\xEF\xBB\xBF) from first field if present
    const bom = "\xEF\xBB\xBF";
    if (std.mem.startsWith(u8, record[0], bom)) {
        const without_bom = try allocator.dupe(u8, record[0][bom.len..]);
        allocator.free(record[0]);
        record[0] = without_bom;
    }

    var cols: std.ArrayList([]const u8) = .empty;
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
        else blk: {
            const renamed = try std.fmt.allocPrint(allocator, "{s}_{d}", .{ base, count });
            // Best-effort warning to stderr; write errors are silently ignored
            stderr_writer.print("warning: duplicate column \"{s}\" renamed to \"{s}\"\n", .{ base, renamed }) catch |err| {
                std.log.err("failed to write warning: {}", .{err});
            };
            break :blk renamed;
        };

        try cols.append(allocator, col);
    }

    return cols.toOwnedSlice(allocator);
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

/// execQuery(db, query, allocator, writer, header, output_format) → !void
/// Pre:  db is open with table `t` populated
///       query is a valid SQL string (not null-terminated)
///       allocator is valid
///       when output_format = .json or .ndjson, header must not be set (caller's responsibility)
/// Post: results are written to writer in the requested output format
///       error.PrepareQueryFailed when sqlite3_prepare_v2 returns non-SQLITE_OK
///       propagates any writer I/O error
fn execQuery(
    allocator: std.mem.Allocator,
    db: *c.sqlite3,
    query: []const u8,
    writer: *std.Io.Writer,
    header: bool,
    output_format: OutputFormat,
    xml_root: []const u8,
    xml_row: []const u8,
) (SqlPipeError || std.mem.Allocator.Error || error{WriteFailed})!void {
    const query_z = try allocator.dupeZ(u8, query);
    defer allocator.free(query_z);

    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(db, query_z.ptr, -1, &stmt, null) != c.SQLITE_OK)
        return error.PrepareQueryFailed;
    defer _ = c.sqlite3_finalize(stmt);

    const col_count = c.sqlite3_column_count(stmt);

    var out_writer = format.OutputWriter.init(output_format, .{
        .header = header,
        .xml_root = xml_root,
        .xml_row = xml_row,
    });
    defer out_writer.deinit(allocator);

    try out_writer.begin(allocator, stmt.?, col_count, writer);
    // Loop invariant I: all SQLITE_ROW results returned so far have been written
    // Bounding function: number of remaining rows in the result set (finite)
    while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
        try out_writer.writeRow(stmt.?, writer);
    }
    try out_writer.end(writer);
}

// ─── Entry point ──────────────────────────────────────

/// fmtThousands(buf, n) → []const u8
/// Pre:  buf.len >= 26 (accommodates any usize value with thousands separators)
/// Post: n is formatted as a decimal string with ',' separating each group of
///       three digits from the right (e.g. 42317 → "42,317", 1000 → "1,000")
fn fmtThousands(buf: []u8, n: usize) []const u8 {
    var tmp: [32]u8 = undefined; // 20 digits max (u64) + safety margin
    const digits = std.fmt.bufPrint(&tmp, "{d}", .{n}) catch unreachable;
    const len = digits.len;
    const first_group = len % 3; // digits in the leading group (0 means groups of 3 from start)
    var out_len: usize = 0;
    // Loop invariant I: buf[0..out_len] = formatted prefix of digits[0..i]
    //                   commas inserted before every third digit counted from the right
    // Bounding function: len - i
    for (digits, 0..) |ch, i| {
        if ((i > 0 and i == first_group) or
            (i > first_group and (i - first_group) % 3 == 0))
        {
            buf[out_len] = ',';
            out_len += 1;
        }
        buf[out_len] = ch;
        out_len += 1;
    }
    return buf[0..out_len];
}

/// printProgress(writer, n, max_rows) → void
/// Pre:  writer is stderr; n > 0
/// Post: "Loading... <n> rows\r" (or "Loading... <n> / <max> rows\r" when max_rows is set)
///       written to writer with carriage return for in-place update; flushed immediately
fn printProgress(writer: *std.Io.Writer, n: usize, max_rows: ?usize) void {
    var count_buf: [32]u8 = undefined;
    const count_str = fmtThousands(&count_buf, n);
    if (max_rows) |limit| {
        var limit_buf: [32]u8 = undefined;
        const limit_str = fmtThousands(&limit_buf, limit);
        writer.print("Loading... {s} / {s} rows\r", .{ count_str, limit_str }) catch |err| {
            std.log.err("failed to write progress: {}", .{err});
        };
    } else {
        writer.print("Loading... {s} rows\r", .{count_str}) catch |err| {
            std.log.err("failed to write progress: {}", .{err});
        };
    }
    writer.flush() catch |err| std.log.err("failed to flush progress: {}", .{err});
}

/// fatal(writer, code, comptime fmt, args) → noreturn
/// Pre:  writer is stderr, code is non-zero ExitCode
/// Post: "error: <message>\n" written to stderr, process exits with code
fn fatal(comptime fmt: []const u8, writer: *std.Io.Writer, code: ExitCode, args: anytype) noreturn {
    writer.print("error: " ++ fmt ++ "\n", args) catch |err| {
        std.log.err("failed to write error message: {}", .{err});
    };
    writer.flush() catch |err| std.log.err("failed to flush: {}", .{err});
    std.process.exit(@intFromEnum(code));
}

/// loadCsvInput loads all CSV rows from stdin into db table `t`.
/// Pre:  db is an open in-memory SQLite handle with no tables yet
///       parsed.delimiter is valid; allocator and writers are valid
/// Post: table `t` exists in db with columns inferred from the CSV header;
///       all CSV rows have been inserted; transaction has been committed
///       returns rows_inserted (data rows only, header not counted)
///       on error: writes message to stderr_writer and exits with appropriate code
fn loadCsvInput(
    allocator: std.mem.Allocator,
    io: std.Io,
    db: *c.sqlite3,
    parsed: ParsedArgs,
    stderr_writer: *std.Io.Writer,
) usize {
    var stdin_buf: [4096]u8 = undefined;
    var stdin_file_reader = std.Io.File.reader(std.Io.File.stdin(), io, &stdin_buf);
    var csv_reader = csv.csvReaderWithDelimiter(allocator, &stdin_file_reader.interface, parsed.delimiter);

    const header_record = csv_reader.nextRecord() catch |err| switch (err) {
        error.UnterminatedQuotedField => fatal("row 1: unterminated quoted field", stderr_writer, .csv_error, .{}),
        else => fatal("row 1: failed to parse CSV header", stderr_writer, .csv_error, .{}),
    } orelse fatal("empty input (no header row)", stderr_writer, .csv_error, .{});
    defer csv_reader.freeRecord(header_record);

    const cols = parseHeader(allocator, header_record, stderr_writer) catch |err| switch (err) {
        error.EmptyColumnName => fatal("row 1: empty column name in header", stderr_writer, .csv_error, .{}),
        error.NoColumns => fatal("row 1: no columns found in header", stderr_writer, .csv_error, .{}),
        else => fatal("row 1: failed to parse header", stderr_writer, .csv_error, .{}),
    };
    defer {
        for (cols) |col| allocator.free(col);
        allocator.free(cols);
    }

    const num_cols = cols.len;
    var csv_row_count: usize = 1; // 1 = header already read

    // ─── Phase 1: determine column types ─────────────────────────────────────
    var row_buffer: std.ArrayList([][]u8) = .empty;
    defer {
        for (row_buffer.items) |row| csv_reader.freeRecord(row);
        row_buffer.deinit(allocator);
    }

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

    sqlite_mod.createTable(allocator, db, cols, types, stderr_writer);

    {
        var errmsg: [*c]u8 = null;
        if (c.sqlite3_exec(db, "BEGIN TRANSACTION", null, null, &errmsg) != c.SQLITE_OK) {
            const msg = if (errmsg != null) std.mem.span(errmsg) else std.mem.span(c.sqlite3_errmsg(db));
            sqlite_mod.fatalSqlWithContext(allocator, db, msg, stderr_writer);
        }
    }

    const stmt = sqlite_mod.prepareInsertStmt(allocator, db, num_cols, stderr_writer);
    defer _ = c.sqlite3_finalize(stmt);

    const is_tty = std.Io.File.isTty(std.Io.File.stderr(), io) catch false;
    var rows_inserted: usize = 0;

    // Insert buffered rows
    for (row_buffer.items) |row| {
        rows_inserted += 1;
        if (parsed.max_rows) |limit| {
            if (rows_inserted > limit)
                fatal("input exceeds --max-rows limit ({d} rows)", stderr_writer, .usage, .{limit});
        }
        insertRowTyped(stmt, db, row, types, @intCast(num_cols)) catch
            sqlite_mod.fatalSqlWithContext(allocator, db, std.mem.span(c.sqlite3_errmsg(db)), stderr_writer);
        if (is_tty and rows_inserted % progress_interval == 0)
            printProgress(stderr_writer, rows_inserted, parsed.max_rows);
    }

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

        rows_inserted += 1;
        if (parsed.max_rows) |limit| {
            if (rows_inserted > limit)
                fatal("input exceeds --max-rows limit ({d} rows)", stderr_writer, .usage, .{limit});
        }
        insertRowTyped(stmt, db, record, types, @intCast(num_cols)) catch
            sqlite_mod.fatalSqlWithContext(allocator, db, std.mem.span(c.sqlite3_errmsg(db)), stderr_writer);
        if (is_tty and rows_inserted % progress_interval == 0)
            printProgress(stderr_writer, rows_inserted, parsed.max_rows);
    }

    {
        var errmsg: [*c]u8 = null;
        const rc = c.sqlite3_exec(db, "COMMIT", null, null, &errmsg);
        if (rc != c.SQLITE_OK) {
            const msg = if (errmsg != null) std.mem.span(errmsg) else std.mem.span(c.sqlite3_errmsg(db));
            sqlite_mod.fatalSqlWithContext(allocator, db, msg, stderr_writer);
        }
        if (errmsg != null) c.sqlite3_free(errmsg);
    }

    return rows_inserted;
}

/// runColumns(allocator, io, args, stderr_writer, stdout_writer) → void
/// Pre:  args is valid; allocator and writers are valid
/// Post: column names from the input header (CSV/JSON/NDJSON) are written to stdout,
///       one per line; when args.verbose is true each line has format "<name> <TYPE>"
///       (CSV only — JSON/NDJSON always show TEXT); exits 0 on success, 2 on parse error
fn runColumns(
    allocator: std.mem.Allocator,
    io: std.Io,
    args: ColumnsArgs,
    stderr_writer: *std.Io.Writer,
    stdout_writer: *std.Io.Writer,
) void {
    switch (args.input_format) {
        .csv, .tsv => {
            const col_delim: []const u8 = if (args.input_format == .tsv) "\t" else args.delimiter;
            var stdin_buf: [4096]u8 = undefined;
            var stdin_file_reader = std.Io.File.reader(std.Io.File.stdin(), io, &stdin_buf);
            var csv_reader = csv.csvReaderWithDelimiter(allocator, &stdin_file_reader.interface, col_delim);

            const header_record = csv_reader.nextRecord() catch |err| switch (err) {
                error.UnterminatedQuotedField => fatal("row 1: unterminated quoted field", stderr_writer, .csv_error, .{}),
                else => fatal("row 1: failed to parse CSV header", stderr_writer, .csv_error, .{}),
            } orelse fatal("empty input (no header row)", stderr_writer, .csv_error, .{});
            defer csv_reader.freeRecord(header_record);

            const cols = parseHeader(allocator, header_record, stderr_writer) catch |err| switch (err) {
                error.EmptyColumnName => fatal("row 1: empty column name in header", stderr_writer, .csv_error, .{}),
                error.NoColumns => fatal("row 1: no columns found in header", stderr_writer, .csv_error, .{}),
                else => fatal("row 1: failed to parse header", stderr_writer, .csv_error, .{}),
            };
            defer {
                for (cols) |col| allocator.free(col);
                allocator.free(cols);
            }

            if (args.verbose) {
                var row_buffer: std.ArrayList([][]u8) = .empty;
                defer {
                    for (row_buffer.items) |row| csv_reader.freeRecord(row);
                    row_buffer.deinit(allocator);
                }
                var data_row: usize = 1;
                while (row_buffer.items.len < inference_buffer_size) {
                    data_row += 1;
                    const rec = csv_reader.nextRecord() catch |err| switch (err) {
                        error.UnterminatedQuotedField => fatal(
                            "row {d}: unterminated quoted field",
                            stderr_writer,
                            .csv_error,
                            .{data_row},
                        ),
                        else => fatal("row {d}: failed to parse CSV", stderr_writer, .csv_error, .{data_row}),
                    } orelse break;
                    if (rec.len == 0) {
                        csv_reader.freeRecord(rec);
                        continue;
                    }
                    row_buffer.append(allocator, rec) catch
                        fatal("out of memory while buffering rows", stderr_writer, .csv_error, .{});
                }
                const types = inferTypes(allocator, row_buffer.items, cols.len) catch
                    fatal("out of memory during type inference", stderr_writer, .csv_error, .{});
                defer allocator.free(types);
                for (cols, types) |col, t| {
                    stdout_writer.print("{s} {s}\n", .{ col, @tagName(t) }) catch |err| {
                        std.log.err("failed to write output: {}", .{err});
                    };
                }
            } else {
                for (cols) |col| {
                    stdout_writer.print("{s}\n", .{col}) catch |err| {
                        std.log.err("failed to write output: {}", .{err});
                    };
                }
            }
        },
        .json => {
            var stdin_buf: [4096]u8 = undefined;
            var stdin_file_reader = std.Io.File.reader(std.Io.File.stdin(), io, &stdin_buf);

            var buf: std.ArrayList(u8) = .empty;
            defer buf.deinit(allocator);
            while (true) {
                const byte = stdin_file_reader.interface.takeByte() catch |err| switch (err) {
                    error.EndOfStream => break,
                    error.ReadFailed => fatal("failed to read JSON input", stderr_writer, .csv_error, .{}),
                };
                buf.append(allocator, byte) catch fatal("out of memory reading JSON", stderr_writer, .csv_error, .{});
            }
            if (buf.items.len == 0) fatal("empty input", stderr_writer, .csv_error, .{});

            var parsed = std.json.parseFromSlice(std.json.Value, allocator, buf.items, .{}) catch
                fatal("failed to parse JSON input", stderr_writer, .csv_error, .{});
            defer parsed.deinit();

            const array = switch (parsed.value) {
                .array => |a| a,
                else => fatal("JSON input must be an array of objects", stderr_writer, .csv_error, .{}),
            };
            if (array.items.len == 0) fatal("empty JSON array: cannot determine column names", stderr_writer, .csv_error, .{});

            const first_obj = switch (array.items[0]) {
                .object => |o| o,
                else => fatal("JSON array elements must be objects", stderr_writer, .csv_error, .{}),
            };

            var ki = first_obj.iterator();
            while (ki.next()) |entry| {
                if (args.verbose) {
                    stdout_writer.print("{s} TEXT\n", .{entry.key_ptr.*}) catch |err| {
                        std.log.err("failed to write output: {}", .{err});
                    };
                } else {
                    stdout_writer.print("{s}\n", .{entry.key_ptr.*}) catch |err| {
                        std.log.err("failed to write output: {}", .{err});
                    };
                }
            }
        },
        .ndjson => {
            var stdin_buf: [4096]u8 = undefined;
            var stdin_file_reader = std.Io.File.reader(std.Io.File.stdin(), io, &stdin_buf);

            // Read until we find a non-empty line
            var line_num: usize = 0;
            while (true) {
                line_num += 1;
                const line = json.readLine(allocator, &stdin_file_reader.interface) catch |err| switch (err) {
                    error.OutOfMemory => fatal("out of memory reading NDJSON", stderr_writer, .csv_error, .{}),
                    error.ReadFailed => fatal("line {d}: failed to read NDJSON", stderr_writer, .csv_error, .{line_num}),
                } orelse fatal("empty NDJSON input", stderr_writer, .csv_error, .{});
                defer allocator.free(line);

                const trimmed = std.mem.trim(u8, line, " \t\r");
                if (trimmed.len == 0) { line_num -= 1; continue; }

                var parsed = std.json.parseFromSlice(std.json.Value, allocator, trimmed, .{}) catch
                    fatal("line 1: failed to parse NDJSON", stderr_writer, .csv_error, .{});
                defer parsed.deinit();

                const obj = switch (parsed.value) {
                    .object => |o| o,
                    else => fatal("line 1: NDJSON element must be a JSON object", stderr_writer, .csv_error, .{}),
                };

                var ki = obj.iterator();
                while (ki.next()) |entry| {
                    if (args.verbose) {
                        stdout_writer.print("{s} TEXT\n", .{entry.key_ptr.*}) catch |err| {
                            std.log.err("failed to write output: {}", .{err});
                        };
                    } else {
                        stdout_writer.print("{s}\n", .{entry.key_ptr.*}) catch |err| {
                            std.log.err("failed to write output: {}", .{err});
                        };
                    }
                }
                break;
            }
        },
        .xml => {
            var stdin_buf: [4096]u8 = undefined;
            var stdin_file_reader = std.Io.File.reader(std.Io.File.stdin(), io, &stdin_buf);

            const names = xml.getXmlColumnNames(allocator, &stdin_file_reader.interface, args.xml_root_input, args.xml_row_input, stderr_writer);
            defer {
                for (names) |name| allocator.free(name);
                allocator.free(names);
            }
            for (names) |name| {
                if (args.verbose) {
                    stdout_writer.print("{s} TEXT\n", .{name}) catch |err| {
                        std.log.err("failed to write output: {}", .{err});
                    };
                } else {
                    stdout_writer.print("{s}\n", .{name}) catch |err| {
                        std.log.err("failed to write output: {}", .{err});
                    };
                }
            }
        },
    }
}

/// runValidate(allocator, io, args, stderr_writer, stdout_writer) → void
/// Pre:  args is valid; allocator and writers are valid
/// Post: the entire input has been parsed (CSV, TSV, JSON, or NDJSON);
///       on success prints "OK: <n> rows, <m> columns (<col> <TYPE>, ...)" to stdout.
///       On parse error, prints the error message to stderr and exits 2.
fn runValidate(
    allocator: std.mem.Allocator,
    io: std.Io,
    args: ValidateArgs,
    stderr_writer: *std.Io.Writer,
    stdout_writer: *std.Io.Writer,
) void {
    switch (args.input_format) {
        .csv, .tsv => {
            const col_delim: []const u8 = if (args.input_format == .tsv) "\t" else args.delimiter;
            var stdin_buf: [4096]u8 = undefined;
            var stdin_file_reader = std.Io.File.reader(std.Io.File.stdin(), io, &stdin_buf);
            var csv_reader = csv.csvReaderWithDelimiter(allocator, &stdin_file_reader.interface, col_delim);

            const header_record = csv_reader.nextRecord() catch |err| switch (err) {
                error.UnterminatedQuotedField => fatal("row 1: unterminated quoted field", stderr_writer, .csv_error, .{}),
                else => fatal("row 1: failed to parse CSV header", stderr_writer, .csv_error, .{}),
            } orelse fatal("empty input (no header row)", stderr_writer, .csv_error, .{});
            defer csv_reader.freeRecord(header_record);

            const cols = parseHeader(allocator, header_record, stderr_writer) catch |err| switch (err) {
                error.EmptyColumnName => fatal("row 1: empty column name in header", stderr_writer, .csv_error, .{}),
                error.NoColumns => fatal("row 1: no columns found in header", stderr_writer, .csv_error, .{}),
                else => fatal("row 1: failed to parse header", stderr_writer, .csv_error, .{}),
            };
            defer {
                for (cols) |col| allocator.free(col);
                allocator.free(cols);
            }

            const num_cols = cols.len;
            var csv_row_count: usize = 1; // header already read
            var data_row_count: usize = 0;

            var row_buffer: std.ArrayList([][]u8) = .empty;
            defer {
                for (row_buffer.items) |row| csv_reader.freeRecord(row);
                row_buffer.deinit(allocator);
            }

            // Buffer up to inference_buffer_size rows for type inference
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
                data_row_count += 1;
                row_buffer.append(allocator, rec) catch
                    fatal("out of memory while buffering rows", stderr_writer, .csv_error, .{});
            }

            const types: []ColumnType = if (args.type_inference) blk: {
                break :blk inferTypes(allocator, row_buffer.items, num_cols) catch
                    fatal("out of memory during type inference", stderr_writer, .csv_error, .{});
            } else blk: {
                const t = allocator.alloc(ColumnType, num_cols) catch
                    fatal("out of memory", stderr_writer, .csv_error, .{});
                @memset(t, .TEXT);
                break :blk t;
            };
            defer allocator.free(types);

            // Stream remaining rows and count them
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
                data_row_count += 1;
            }

            var count_buf: [32]u8 = undefined;
            const count_str = fmtThousands(&count_buf, data_row_count);

            stdout_writer.print("OK: {s} rows, {d} columns (", .{ count_str, num_cols }) catch |err| {
                std.log.err("failed to write output: {}", .{err});
                std.process.exit(@intFromEnum(ExitCode.usage));
            };

            for (cols, types, 0..) |col, t, i| {
                if (i > 0) {
                    stdout_writer.writeAll(", ") catch |err| {
                        std.log.err("failed to write output: {}", .{err});
                        std.process.exit(@intFromEnum(ExitCode.usage));
                    };
                }
                stdout_writer.print("{s} {s}", .{ col, @tagName(t) }) catch |err| {
                    std.log.err("failed to write output: {}", .{err});
                    std.process.exit(@intFromEnum(ExitCode.usage));
                };
            }
            stdout_writer.writeAll(")\n") catch |err| {
                std.log.err("failed to write output: {}", .{err});
                std.process.exit(@intFromEnum(ExitCode.usage));
            };
        },
        .json => {
            var stdin_buf: [4096]u8 = undefined;
            var stdin_file_reader = std.Io.File.reader(std.Io.File.stdin(), io, &stdin_buf);

            var buf: std.ArrayList(u8) = .empty;
            defer buf.deinit(allocator);
            while (true) {
                const byte = stdin_file_reader.interface.takeByte() catch |err| switch (err) {
                    error.EndOfStream => break,
                    error.ReadFailed => fatal("failed to read JSON input", stderr_writer, .csv_error, .{}),
                };
                buf.append(allocator, byte) catch fatal("out of memory reading JSON", stderr_writer, .csv_error, .{});
            }
            if (buf.items.len == 0) fatal("empty input", stderr_writer, .csv_error, .{});

            var parsed = std.json.parseFromSlice(std.json.Value, allocator, buf.items, .{}) catch
                fatal("failed to parse JSON input", stderr_writer, .csv_error, .{});
            defer parsed.deinit();

            const array = switch (parsed.value) {
                .array => |a| a,
                else => fatal("JSON input must be an array of objects", stderr_writer, .csv_error, .{}),
            };
            if (array.items.len == 0) fatal("empty JSON array: cannot determine column names", stderr_writer, .csv_error, .{});

            const first_obj = switch (array.items[0]) {
                .object => |o| o,
                else => fatal("JSON array elements must be objects", stderr_writer, .csv_error, .{}),
            };

            var num_cols: usize = 0;
            var ki = first_obj.iterator();
            while (ki.next()) |_| num_cols += 1;

            var count_buf: [32]u8 = undefined;
            const count_str = fmtThousands(&count_buf, array.items.len);
            stdout_writer.print("OK: {s} rows, {d} columns (", .{ count_str, num_cols }) catch |err| {
                std.log.err("failed to write output: {}", .{err});
                std.process.exit(@intFromEnum(ExitCode.usage));
            };
            ki = first_obj.iterator();
            var col_i: usize = 0;
            while (ki.next()) |entry| : (col_i += 1) {
                if (col_i > 0) stdout_writer.writeAll(", ") catch |err| {
                    std.log.err("failed to write output: {}", .{err});
                    std.process.exit(@intFromEnum(ExitCode.usage));
                };
                stdout_writer.print("{s} TEXT", .{entry.key_ptr.*}) catch |err| {
                    std.log.err("failed to write output: {}", .{err});
                    std.process.exit(@intFromEnum(ExitCode.usage));
                };
            }
            stdout_writer.writeAll(")\n") catch |err| {
                std.log.err("failed to write output: {}", .{err});
                std.process.exit(@intFromEnum(ExitCode.usage));
            };
        },
        .ndjson => {
            var stdin_buf: [4096]u8 = undefined;
            var stdin_file_reader = std.Io.File.reader(std.Io.File.stdin(), io, &stdin_buf);

            var line_num: usize = 0;
            var row_count: usize = 0;
            var cols_owned: ?[][]u8 = null;
            defer if (cols_owned) |cs| {
                for (cs) |col| allocator.free(col);
                allocator.free(cs);
            };

            while (true) {
                line_num += 1;
                const line = json.readLine(allocator, &stdin_file_reader.interface) catch |err| switch (err) {
                    error.OutOfMemory => fatal("out of memory reading NDJSON", stderr_writer, .csv_error, .{}),
                    error.ReadFailed => fatal("line {d}: failed to read NDJSON", stderr_writer, .csv_error, .{line_num}),
                } orelse break;
                defer allocator.free(line);

                const trimmed = std.mem.trim(u8, line, " \t\r");
                if (trimmed.len == 0) {
                    line_num -= 1;
                    continue;
                }

                var parsed_line = std.json.parseFromSlice(std.json.Value, allocator, trimmed, .{}) catch
                    fatal("line {d}: failed to parse NDJSON", stderr_writer, .csv_error, .{line_num});
                defer parsed_line.deinit();

                const obj = switch (parsed_line.value) {
                    .object => |o| o,
                    else => fatal("line {d}: NDJSON element must be a JSON object", stderr_writer, .csv_error, .{line_num}),
                };

                if (cols_owned == null) {
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
                }
                row_count += 1;
            }

            if (cols_owned == null) fatal("empty NDJSON input", stderr_writer, .csv_error, .{});

            const cols = cols_owned.?;
            var count_buf: [32]u8 = undefined;
            const count_str = fmtThousands(&count_buf, row_count);
            stdout_writer.print("OK: {s} rows, {d} columns (", .{ count_str, cols.len }) catch |err| {
                std.log.err("failed to write output: {}", .{err});
                std.process.exit(@intFromEnum(ExitCode.usage));
            };
            for (cols, 0..) |col, i| {
                if (i > 0) stdout_writer.writeAll(", ") catch |err| {
                    std.log.err("failed to write output: {}", .{err});
                    std.process.exit(@intFromEnum(ExitCode.usage));
                };
                stdout_writer.print("{s} TEXT", .{col}) catch |err| {
                    std.log.err("failed to write output: {}", .{err});
                    std.process.exit(@intFromEnum(ExitCode.usage));
                };
            }
            stdout_writer.writeAll(")\n") catch |err| {
                std.log.err("failed to write output: {}", .{err});
                std.process.exit(@intFromEnum(ExitCode.usage));
            };
        },
        .xml => {
            var stdin_buf: [4096]u8 = undefined;
            var stdin_file_reader = std.Io.File.reader(std.Io.File.stdin(), io, &stdin_buf);

            const summary = xml.summarizeXml(allocator, &stdin_file_reader.interface, args.xml_root_input, args.xml_row_input, stderr_writer);
            defer {
                for (summary.col_names) |name| allocator.free(name);
                allocator.free(summary.col_names);
            }

            var count_buf: [32]u8 = undefined;
            const count_str = fmtThousands(&count_buf, summary.row_count);
            stdout_writer.print("OK: {s} rows, {d} columns (", .{ count_str, summary.col_names.len }) catch |err| {
                std.log.err("failed to write output: {}", .{err});
                std.process.exit(@intFromEnum(ExitCode.usage));
            };
            for (summary.col_names, 0..) |name, i| {
                if (i > 0) stdout_writer.writeAll(", ") catch |err| {
                    std.log.err("failed to write output: {}", .{err});
                    std.process.exit(@intFromEnum(ExitCode.usage));
                };
                stdout_writer.print("{s} TEXT", .{name}) catch |err| {
                    std.log.err("failed to write output: {}", .{err});
                    std.process.exit(@intFromEnum(ExitCode.usage));
                };
            }
            stdout_writer.writeAll(")\n") catch |err| {
                std.log.err("failed to write output: {}", .{err});
                std.process.exit(@intFromEnum(ExitCode.usage));
            };
        },
    }
}

/// runSample(allocator, io, args, stderr_writer, stdout_writer) → void
/// Pre:  args is valid; allocator and writers are valid; input_format is csv or tsv
/// Post: a schema comment block is written to stderr (column names + inferred types,
///       or all TEXT if args.type_inference is false, each line prefixed with "#") and
///       a header row + first args.n data rows are written to stdout as delimited text.
///       Exits 2 on parse error, 1 on stdout write error. No query required.
fn runSample(
    allocator: std.mem.Allocator,
    io: std.Io,
    args: SampleArgs,
    stderr_writer: *std.Io.Writer,
    stdout_writer: *std.Io.Writer,
) void {
    switch (args.input_format) {
        .json, .ndjson, .xml => fatal(
            "--sample is only supported with CSV and TSV input",
            stderr_writer,
            .usage,
            .{},
        ),
        .csv, .tsv => {
            const col_delim: []const u8 = if (args.input_format == .tsv) "\t" else args.delimiter;
            var stdin_buf: [4096]u8 = undefined;
            var stdin_file_reader = std.Io.File.reader(std.Io.File.stdin(), io, &stdin_buf);
            var csv_reader = csv.csvReaderWithDelimiter(allocator, &stdin_file_reader.interface, col_delim);

            const header_record = csv_reader.nextRecord() catch |err| switch (err) {
                error.UnterminatedQuotedField => fatal("row 1: unterminated quoted field", stderr_writer, .csv_error, .{}),
                else => fatal("row 1: failed to parse CSV header", stderr_writer, .csv_error, .{}),
            } orelse fatal("empty input (no header row)", stderr_writer, .csv_error, .{});
            defer csv_reader.freeRecord(header_record);

            const cols = parseHeader(allocator, header_record, stderr_writer) catch |err| switch (err) {
                error.EmptyColumnName => fatal("row 1: empty column name in header", stderr_writer, .csv_error, .{}),
                error.NoColumns => fatal("row 1: no columns found in header", stderr_writer, .csv_error, .{}),
                else => fatal("row 1: failed to parse header", stderr_writer, .csv_error, .{}),
            };
            defer {
                for (cols) |col| allocator.free(col);
                allocator.free(cols);
            }

            // Buffer max(inference_buffer_size, n) rows for type inference
            const buf_size = @max(inference_buffer_size, args.n);
            var row_buffer: std.ArrayList([][]u8) = .empty;
            defer {
                for (row_buffer.items) |row| csv_reader.freeRecord(row);
                row_buffer.deinit(allocator);
            }

            var csv_row_count: usize = 1;
            // Loop invariant I: row_buffer contains all non-empty data rows read so far (up to buf_size)
            // Bounding function: buf_size - row_buffer.items.len
            while (row_buffer.items.len < buf_size) {
                const rec = csv_reader.nextRecord() catch |err| switch (err) {
                    error.UnterminatedQuotedField => fatal(
                        "row {d}: unterminated quoted field",
                        stderr_writer,
                        .csv_error,
                        .{csv_row_count + 1},
                    ),
                    else => fatal("row {d}: failed to parse CSV", stderr_writer, .csv_error, .{csv_row_count + 1}),
                } orelse break;
                csv_row_count += 1;
                if (rec.len == 0) {
                    csv_reader.freeRecord(rec);
                    continue;
                }
                row_buffer.append(allocator, rec) catch
                    fatal("out of memory while buffering rows", stderr_writer, .csv_error, .{});
            }

            const types: []ColumnType = if (args.type_inference) blk: {
                break :blk inferTypes(allocator, row_buffer.items, cols.len) catch
                    fatal("out of memory during type inference", stderr_writer, .csv_error, .{});
            } else blk: {
                const t = allocator.alloc(ColumnType, cols.len) catch
                    fatal("out of memory", stderr_writer, .csv_error, .{});
                @memset(t, .TEXT);
                break :blk t;
            };
            defer allocator.free(types);

            // ─── Print schema block to stderr ─────────────────────────────────────
            // Compute max column name width for aligned output
            var max_col_width: usize = 0;
            for (cols) |col| max_col_width = @max(max_col_width, col.len);

            stderr_writer.print("# Schema ({d} columns):\n", .{cols.len}) catch |err| {
                std.log.err("failed to write schema: {}", .{err});
            };
            // Loop invariant I: cols[0..i] have been printed with aligned type annotation
            // Bounding function: cols.len - i
            for (cols, types) |col, t| {
                stderr_writer.writeAll("#   ") catch |err| {
                    std.log.err("failed to write schema: {}", .{err});
                };
                stderr_writer.writeAll(col) catch |err| {
                    std.log.err("failed to write schema: {}", .{err});
                };
                // Pad to max_col_width + 2 spaces before the type
                var p: usize = col.len;
                while (p < max_col_width + 2) : (p += 1) {
                    stderr_writer.writeByte(' ') catch |err| {
                        std.log.err("failed to write schema: {}", .{err});
                    };
                }
                stderr_writer.print("{s}\n", .{@tagName(t)}) catch |err| {
                    std.log.err("failed to write schema: {}", .{err});
                };
            }
            stderr_writer.flush() catch |err| std.log.err("failed to flush stderr: {}", .{err});

            // ─── Print header row to stdout ────────────────────────────────────────
            // Loop invariant I: cols[0..i] names have been written, separated by col_delim
            // Bounding function: cols.len - i
            for (cols, 0..) |col, i| {
                if (i > 0) stdout_writer.writeAll(col_delim) catch
                    fatal("failed to write header", stderr_writer, .csv_error, .{});
                format.writeField(stdout_writer, col, col_delim) catch
                    fatal("failed to write header", stderr_writer, .csv_error, .{});
            }
            stdout_writer.writeByte('\n') catch
                fatal("failed to write header newline", stderr_writer, .csv_error, .{});

            // ─── Print first n data rows to stdout ────────────────────────────────
            const rows_to_print = @min(args.n, row_buffer.items.len);
            // Loop invariant I: row_buffer[0..r] have been printed as delimited rows
            // Bounding function: rows_to_print - r
            for (row_buffer.items[0..rows_to_print]) |row| {
                var col_idx: usize = 0;
                // Loop invariant I: cols[0..col_idx] fields have been written for this row
                // Bounding function: cols.len - col_idx
                while (col_idx < cols.len) : (col_idx += 1) {
                    if (col_idx > 0) stdout_writer.writeAll(col_delim) catch
                        fatal("failed to write field separator", stderr_writer, .csv_error, .{});
                    const val: []const u8 = if (col_idx < row.len) row[col_idx] else "";
                    format.writeField(stdout_writer, val, col_delim) catch
                        fatal("failed to write field", stderr_writer, .csv_error, .{});
                }
                stdout_writer.writeByte('\n') catch
                    fatal("failed to write row newline", stderr_writer, .csv_error, .{});
            }
        },
    }
}

/// run(allocator, io, parsed, stderr_writer, stdout_writer) → void
/// Pre:  parsed contains a valid query; allocator and writers are valid
/// Post: input from stdin has been loaded (dispatched on parsed.input_format),
///       query executed, results written to stdout in parsed.output_format
///       On error, an "error: ..." message is written to stderr and process
///       exits with the appropriate ExitCode (1, 2, or 3)
fn run(
    allocator: std.mem.Allocator,
    io: std.Io,
    parsed: ParsedArgs,
    stderr_writer: *std.Io.Writer,
    stdout_writer: *std.Io.Writer,
) void {
    const query = parsed.query;

    const db = sqlite_mod.openDb(stderr_writer);
    defer _ = c.sqlite3_close(db);

    const start_ts = std.Io.Timestamp.now(io, .awake);

    // Load input into `t` — dispatch on input format
    const rows_inserted: usize = switch (parsed.input_format) {
        .csv => loadCsvInput(allocator, io, db, parsed, stderr_writer),
        .tsv => blk: {
            // TSV is CSV with tab delimiter; override delimiter and reuse the CSV loader
            var tsv_parsed = parsed;
            tsv_parsed.delimiter = "\t";
            break :blk loadCsvInput(allocator, io, db, tsv_parsed, stderr_writer);
        },
        .json => blk: {
            var stdin_buf: [4096]u8 = undefined;
            var stdin_reader = std.Io.File.reader(std.Io.File.stdin(), io, &stdin_buf);
            break :blk json.loadJsonArray(allocator, &stdin_reader.interface, db, parsed.max_rows, stderr_writer);
        },
        .ndjson => blk: {
            var stdin_buf: [4096]u8 = undefined;
            var stdin_reader = std.Io.File.reader(std.Io.File.stdin(), io, &stdin_buf);
            break :blk json.loadNdjsonInput(allocator, &stdin_reader.interface, db, parsed.max_rows, stderr_writer);
        },
        .xml => blk: {
            var stdin_buf: [4096]u8 = undefined;
            var stdin_reader = std.Io.File.reader(std.Io.File.stdin(), io, &stdin_buf);
            break :blk xml.loadXmlInput(allocator, &stdin_reader.interface, db, parsed.xml_root_input, parsed.xml_row_input, parsed.max_rows, stderr_writer);
        },
    };

    // Print row count and elapsed time to stderr when stderr is a TTY or --verbose is set.
    const is_tty = std.Io.File.isTty(std.Io.File.stderr(), io) catch false;
    if (!parsed.silent and (parsed.verbose or is_tty)) {
        const end_ts = std.Io.Timestamp.now(io, .awake);
        const elapsed_ns: i96 = end_ts.nanoseconds - start_ts.nanoseconds;
        const elapsed_ms: u64 = @intCast(@max(@as(i96, 0), @divTrunc(elapsed_ns, std.time.ns_per_ms)));
        var count_buf: [32]u8 = undefined;
        const count_str = fmtThousands(&count_buf, rows_inserted);
        const secs = elapsed_ms / 1000;
        const frac = (elapsed_ms % 1000) / 100;
        if (is_tty and rows_inserted >= progress_interval) {
            stderr_writer.writeAll("\r\x1b[K") catch |err| std.log.err("failed to clear progress line: {}", .{err});
        }
        stderr_writer.print("Loaded {s} rows in {d}.{d}s\n", .{ count_str, secs, frac }) catch |err| {
            std.log.err("failed to write row count: {}", .{err});
        };
        stderr_writer.flush() catch |err| std.log.err("failed to flush stderr: {}", .{err});
    }

    execQuery(allocator, db, query, stdout_writer, parsed.header, parsed.output_format, parsed.xml_root, parsed.xml_row) catch {
        stdout_writer.flush() catch |err| std.log.err("failed to flush output before fatal: {}", .{err});
        sqlite_mod.fatalSqlWithContext(allocator, db, std.mem.span(c.sqlite3_errmsg(db)), stderr_writer);
    };
}

pub fn main(init: std.process.Init.Minimal) void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var io = std.Io.Threaded.init_single_threaded;

    var stderr_buf: [1024]u8 = undefined;
    var stderr_file_writer = std.Io.File.writer(std.Io.File.stderr(), io.io(), &stderr_buf);
    const stderr_writer: *std.Io.Writer = &stderr_file_writer.interface;

    var stdout_buf: [4096]u8 = undefined;
    var stdout_file_writer = std.Io.File.writer(std.Io.File.stdout(), io.io(), &stdout_buf);
    const stdout_writer: *std.Io.Writer = &stdout_file_writer.interface;

    var args_arena = std.heap.ArenaAllocator.init(allocator);
    defer args_arena.deinit();
    const args = init.args.toSlice(args_arena.allocator()) catch
        fatal("failed to read process arguments", stderr_writer, .usage, .{});

    const args_result = parseArgs(args) catch |err| {
        switch (err) {
            error.IncompatibleFlags => {
                stderr_writer.writeAll(
                    "error: --header cannot be combined with non-CSV/TSV output format\n",
                ) catch |werr| std.log.err("failed to write error message: {}", .{werr});
                stderr_writer.flush() catch |ferr| std.log.err("failed to flush: {}", .{ferr});
                std.process.exit(@intFromEnum(ExitCode.usage));
            },
            error.SilentVerboseConflict => {
                stderr_writer.writeAll(
                    "error: --silent cannot be combined with --verbose\n",
                ) catch |werr| std.log.err("failed to write error message: {}", .{werr});
                stderr_writer.flush() catch |ferr| std.log.err("failed to flush: {}", .{ferr});
                std.process.exit(@intFromEnum(ExitCode.usage));
            },
            error.InvalidMaxRows => {
                stderr_writer.writeAll("error: --max-rows must be a positive integer\n") catch |werr| {
                    std.log.err("failed to write error message: {}", .{werr});
                };
                stderr_writer.flush() catch |ferr| std.log.err("failed to flush: {}", .{ferr});
                std.process.exit(@intFromEnum(ExitCode.usage));
            },
            error.InvalidInputFormat => {
                stderr_writer.writeAll(
                    "error: unknown input format; supported: csv, tsv, json, ndjson, xml\n",
                ) catch |werr| std.log.err("failed to write error message: {}", .{werr});
                stderr_writer.flush() catch |ferr| std.log.err("failed to flush: {}", .{ferr});
                std.process.exit(@intFromEnum(ExitCode.usage));
            },
            error.InvalidOutputFormat => {
                stderr_writer.writeAll(
                    "error: unknown output format; supported: csv, tsv, json, ndjson, xml\n",
                ) catch |werr| std.log.err("failed to write error message: {}", .{werr});
                stderr_writer.flush() catch |ferr| std.log.err("failed to flush: {}", .{ferr});
                std.process.exit(@intFromEnum(ExitCode.usage));
            },
            error.ColumnsWithQuery => {
                stderr_writer.writeAll("error: --columns cannot be combined with a query argument\n") catch |werr| {
                    std.log.err("failed to write error message: {}", .{werr});
                };
                stderr_writer.flush() catch |ferr| std.log.err("failed to flush: {}", .{ferr});
                std.process.exit(@intFromEnum(ExitCode.usage));
            },
            error.ValidateWithQuery => {
                stderr_writer.writeAll("error: --validate cannot be combined with a query argument\n") catch |werr| {
                    std.log.err("failed to write error message: {}", .{werr});
                };
                stderr_writer.flush() catch |ferr| std.log.err("failed to flush: {}", .{ferr});
                std.process.exit(@intFromEnum(ExitCode.usage));
            },
            error.InvalidOutputPath => {
                stderr_writer.writeAll("error: --output requires a non-empty file path\n") catch |werr| {
                    std.log.err("failed to write error message: {}", .{werr});
                };
                stderr_writer.flush() catch |ferr| std.log.err("failed to flush: {}", .{ferr});
                std.process.exit(@intFromEnum(ExitCode.usage));
            },
            error.OutputWithColumns => {
                stderr_writer.writeAll("error: --output cannot be combined with --columns\n") catch |werr| {
                    std.log.err("failed to write error message: {}", .{werr});
                };
                stderr_writer.flush() catch |ferr| std.log.err("failed to flush: {}", .{ferr});
                std.process.exit(@intFromEnum(ExitCode.usage));
            },
            error.OutputWithValidate => {
                stderr_writer.writeAll("error: --output cannot be combined with --validate\n") catch |werr| {
                    std.log.err("failed to write error message: {}", .{werr});
                };
                stderr_writer.flush() catch |ferr| std.log.err("failed to flush: {}", .{ferr});
                std.process.exit(@intFromEnum(ExitCode.usage));
            },
            error.ValidateWithColumns => {
                stderr_writer.writeAll("error: --validate cannot be combined with --columns\n") catch |werr| {
                    std.log.err("failed to write error message: {}", .{werr});
                };
                stderr_writer.flush() catch |ferr| std.log.err("failed to flush: {}", .{ferr});
                std.process.exit(@intFromEnum(ExitCode.usage));
            },
            error.SampleWithQuery => {
                stderr_writer.writeAll("error: --sample cannot be combined with a query argument\n") catch |werr| {
                    std.log.err("failed to write error message: {}", .{werr});
                };
                stderr_writer.flush() catch |ferr| std.log.err("failed to flush: {}", .{ferr});
                std.process.exit(@intFromEnum(ExitCode.usage));
            },
            error.SampleWithJson => {
                stderr_writer.writeAll("error: --sample cannot be combined with --json or a JSON output format\n") catch |werr| {
                    std.log.err("failed to write error message: {}", .{werr});
                };
                stderr_writer.flush() catch |ferr| std.log.err("failed to flush: {}", .{ferr});
                std.process.exit(@intFromEnum(ExitCode.usage));
            },
            error.SampleWithColumns => {
                stderr_writer.writeAll("error: --sample cannot be combined with --columns\n") catch |werr| {
                    std.log.err("failed to write error message: {}", .{werr});
                };
                stderr_writer.flush() catch |ferr| std.log.err("failed to flush: {}", .{ferr});
                std.process.exit(@intFromEnum(ExitCode.usage));
            },
            error.SampleWithValidate => {
                stderr_writer.writeAll("error: --sample cannot be combined with --validate\n") catch |werr| {
                    std.log.err("failed to write error message: {}", .{werr});
                };
                stderr_writer.flush() catch |ferr| std.log.err("failed to flush: {}", .{ferr});
                std.process.exit(@intFromEnum(ExitCode.usage));
            },
            error.SampleWithOutput => {
                stderr_writer.writeAll("error: --sample cannot be combined with --output\n") catch |werr| {
                    std.log.err("failed to write error message: {}", .{werr});
                };
                stderr_writer.flush() catch |ferr| std.log.err("failed to flush: {}", .{ferr});
                std.process.exit(@intFromEnum(ExitCode.usage));
            },
            error.InvalidSampleCount => {
                stderr_writer.writeAll("error: --sample requires a positive integer value\n") catch |werr| {
                    std.log.err("failed to write error message: {}", .{werr});
                };
                stderr_writer.flush() catch |ferr| std.log.err("failed to flush: {}", .{ferr});
                std.process.exit(@intFromEnum(ExitCode.usage));
            },
            error.MissingXmlFlagValue => {
                stderr_writer.writeAll(
                    "error: --xml-root and --xml-row require a value\n",
                ) catch |werr| std.log.err("failed to write error message: {}", .{werr});
                stderr_writer.flush() catch |ferr| std.log.err("failed to flush: {}", .{ferr});
                std.process.exit(@intFromEnum(ExitCode.usage));
            },
            error.InvalidXmlName => {
                stderr_writer.writeAll(
                    "error: --xml-root and --xml-row must be valid XML element names (letter/underscore first, then letters/digits/-/._/:)\n",
                ) catch |werr| std.log.err("failed to write error message: {}", .{werr});
                stderr_writer.flush() catch |ferr| std.log.err("failed to flush: {}", .{ferr});
                std.process.exit(@intFromEnum(ExitCode.usage));
            },
            else => {},
        }
        printUsage(stderr_writer) catch |werr| {
            std.log.err("failed to write usage: {}", .{werr});
        };
        stderr_writer.flush() catch |ferr| std.log.err("failed to flush: {}", .{ferr});
        std.process.exit(@intFromEnum(ExitCode.usage));
    };

    switch (args_result) {
        .help => {
            printUsage(stderr_writer) catch |err| {
                std.log.err("failed to write usage: {}", .{err});
            };
            stderr_writer.flush() catch |err| std.log.err("failed to flush: {}", .{err});
            std.process.exit(@intFromEnum(ExitCode.success));
        },
        .version => {
            stderr_writer.print("sql-pipe {s}\n", .{VERSION}) catch |err| {
                std.log.err("failed to write version: {}", .{err});
            };
            stderr_writer.flush() catch |err| std.log.err("failed to flush: {}", .{err});
            std.process.exit(@intFromEnum(ExitCode.success));
        },
        .columns => |col_args| {
            runColumns(allocator, io.io(), col_args, stderr_writer, stdout_writer);
            stdout_file_writer.flush() catch |err| {
                std.log.err("failed to flush stdout: {}", .{err});
            };
            stderr_file_writer.flush() catch |err| {
                std.log.err("failed to flush stderr: {}", .{err});
            };
        },
        .validate => |val_args| {
            runValidate(allocator, io.io(), val_args, stderr_writer, stdout_writer);
            stdout_file_writer.flush() catch |err| {
                std.log.err("failed to flush stdout: {}", .{err});
            };
            stderr_file_writer.flush() catch |err| {
                std.log.err("failed to flush stderr: {}", .{err});
            };
        },
        .sample => |sample_args| {
            runSample(allocator, io.io(), sample_args, stderr_writer, stdout_writer);
            stdout_file_writer.flush() catch |err| {
                std.log.err("failed to flush stdout: {}", .{err});
            };
            stderr_file_writer.flush() catch |err| {
                std.log.err("failed to flush stderr: {}", .{err});
            };
        },
        .parsed => |parsed| {
            if (parsed.output) |output_path| {
                const output_file = std.Io.Dir.createFile(std.Io.Dir.cwd(), io.io(), output_path, .{}) catch |err| {
                    stderr_writer.print("error: cannot create output file '{s}': {s}\n", .{ output_path, @errorName(err) }) catch |werr| {
                        std.log.err("failed to write error message: {}", .{werr});
                    };
                    stderr_writer.flush() catch |ferr| std.log.err("failed to flush: {}", .{ferr});
                    std.process.exit(@intFromEnum(ExitCode.usage));
                };
                defer std.Io.File.close(output_file, io.io());
                var output_buf: [4096]u8 = undefined;
                var output_file_writer = std.Io.File.writer(output_file, io.io(), &output_buf);
                run(allocator, io.io(), parsed, stderr_writer, &output_file_writer.interface);
                output_file_writer.flush() catch |err| {
                    std.log.err("failed to flush output file: {}", .{err});
                };
            } else {
                run(allocator, io.io(), parsed, stderr_writer, stdout_writer);
                stdout_file_writer.flush() catch |err| {
                    std.log.err("failed to flush stdout: {}", .{err});
                };
            }
            stderr_file_writer.flush() catch |err| {
                std.log.err("failed to flush stderr: {}", .{err});
            };
        },
    }
}
