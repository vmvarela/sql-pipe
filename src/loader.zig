//! CSV loader — type inference, header parsing, and loading CSV/TSV into SQLite.

const std = @import("std");
const c = @import("c");
const csv_mod = @import("csv.zig");
const sqlite_mod = @import("sqlite.zig");
const args_mod = @import("args.zig");

const ColumnType = sqlite_mod.ColumnType;
const sqlite_static = sqlite_mod.sqlite_static;

const fatal = sqlite_mod.fatal;
const fatalSqlWithContext = sqlite_mod.fatalSqlWithContext;

/// Number of rows buffered from stdin to infer column types.
pub const inference_buffer_size: usize = 100;

/// Number of rows between progress indicator updates.
pub const progress_interval: usize = 10_000;

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
pub fn isInteger(val: []const u8) bool {
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
pub fn isReal(val: []const u8) bool {
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
pub fn inferTypes(
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
pub fn parseHeader(
    allocator: std.mem.Allocator,
    record: [][]u8,
    stderr_writer: *std.Io.Writer,
) (args_mod.SqlPipeError || std.mem.Allocator.Error)![][]const u8 {
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
pub fn insertRowTyped(
    stmt: *c.sqlite3_stmt,
    db: *c.sqlite3,
    row: [][]u8,
    types: []const ColumnType,
    param_count: c_int,
) args_mod.SqlPipeError!void {
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

/// fmtThousands(buf, n) → []const u8
/// Pre:  buf.len >= 26 (accommodates any usize value with thousands separators)
/// Post: n is formatted as a decimal string with ',' separating each group of
///       three digits from the right (e.g. 42317 → "42,317", 1000 → "1,000")
pub fn fmtThousands(buf: []u8, n: usize) []const u8 {
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
pub fn printProgress(writer: *std.Io.Writer, n: usize, max_rows: ?usize) void {
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

/// loadCsvInput loads all CSV rows from stdin into db table `t`.
/// Pre:  db is an open in-memory SQLite handle with no tables yet
///       parsed.delimiter is valid; allocator and writers are valid
/// Post: table `t` exists in db with columns inferred from the CSV header;
///       all CSV rows have been inserted; transaction has been committed
///       returns rows_inserted (data rows only, header not counted)
///       on error: writes message to stderr_writer and exits with appropriate code
pub fn loadCsvInput(
    allocator: std.mem.Allocator,
    io: std.Io,
    db: *c.sqlite3,
    parsed: args_mod.ParsedArgs,
    stderr_writer: *std.Io.Writer,
) usize {
    var stdin_buf: [4096]u8 = undefined;
    var stdin_file_reader = std.Io.File.reader(std.Io.File.stdin(), io, &stdin_buf);
    var csv_reader = csv_mod.csvReaderWithDelimiter(allocator, &stdin_file_reader.interface, parsed.delimiter);

    const header_record = csv_reader.nextRecord() catch |err| switch (err) {
        error.UnterminatedQuotedField => fatal("row 1: unterminated quoted field", stderr_writer, sqlite_mod.exit_parse, .{}),
        else => fatal("row 1: failed to parse CSV header", stderr_writer, sqlite_mod.exit_parse, .{}),
    } orelse fatal("empty input (no header row)", stderr_writer, sqlite_mod.exit_parse, .{});
    defer csv_reader.freeRecord(header_record);

    const cols = parseHeader(allocator, header_record, stderr_writer) catch |err| switch (err) {
        error.EmptyColumnName => fatal("row 1: empty column name in header", stderr_writer, sqlite_mod.exit_parse, .{}),
        error.NoColumns => fatal("row 1: no columns found in header", stderr_writer, sqlite_mod.exit_parse, .{}),
        else => fatal("row 1: failed to parse header", stderr_writer, sqlite_mod.exit_parse, .{}),
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
                    sqlite_mod.exit_parse,
                    .{csv_row_count + 1},
                ),
                else => fatal(
                    "row {d}: failed to parse CSV",
                    stderr_writer,
                    sqlite_mod.exit_parse,
                    .{csv_row_count + 1},
                ),
            } orelse break;
            csv_row_count += 1;
            if (rec.len == 0) {
                csv_reader.freeRecord(rec);
                continue;
            }
            row_buffer.append(allocator, rec) catch
                fatal("out of memory while buffering rows", stderr_writer, sqlite_mod.exit_parse, .{});
        }
        break :blk inferTypes(allocator, row_buffer.items, num_cols) catch
            fatal("out of memory during type inference", stderr_writer, sqlite_mod.exit_parse, .{});
    } else blk: {
        const t = allocator.alloc(ColumnType, num_cols) catch
            fatal("out of memory", stderr_writer, sqlite_mod.exit_parse, .{});
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
            fatalSqlWithContext(allocator, db, msg, stderr_writer);
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
                fatal("input exceeds --max-rows limit ({d} rows)", stderr_writer, sqlite_mod.exit_usage, .{limit});
        }
        insertRowTyped(stmt, db, row, types, @intCast(num_cols)) catch
            fatalSqlWithContext(allocator, db, std.mem.span(c.sqlite3_errmsg(db)), stderr_writer);
        if (is_tty and rows_inserted % progress_interval == 0)
            printProgress(stderr_writer, rows_inserted, parsed.max_rows);
    }

    // Stream remaining rows from stdin
    while (true) {
        const record = csv_reader.nextRecord() catch |err| switch (err) {
            error.UnterminatedQuotedField => fatal(
                "row {d}: unterminated quoted field",
                stderr_writer,
                sqlite_mod.exit_parse,
                .{csv_row_count + 1},
            ),
            else => fatal(
                "row {d}: failed to parse CSV",
                stderr_writer,
                sqlite_mod.exit_parse,
                .{csv_row_count + 1},
            ),
        } orelse break;
        csv_row_count += 1;
        defer csv_reader.freeRecord(record);

        if (record.len == 0) continue;

        rows_inserted += 1;
        if (parsed.max_rows) |limit| {
            if (rows_inserted > limit)
                fatal("input exceeds --max-rows limit ({d} rows)", stderr_writer, sqlite_mod.exit_usage, .{limit});
        }
        insertRowTyped(stmt, db, record, types, @intCast(num_cols)) catch
            fatalSqlWithContext(allocator, db, std.mem.span(c.sqlite3_errmsg(db)), stderr_writer);
        if (is_tty and rows_inserted % progress_interval == 0)
            printProgress(stderr_writer, rows_inserted, parsed.max_rows);
    }

    {
        var errmsg: [*c]u8 = null;
        const rc = c.sqlite3_exec(db, "COMMIT", null, null, &errmsg);
        if (rc != c.SQLITE_OK) {
            const msg = if (errmsg != null) std.mem.span(errmsg) else std.mem.span(c.sqlite3_errmsg(db));
            fatalSqlWithContext(allocator, db, msg, stderr_writer);
        }
        if (errmsg != null) c.sqlite3_free(errmsg);
    }

    return rows_inserted;
}
