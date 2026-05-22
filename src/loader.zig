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

/// isDate(val) → bool
/// Pre:  val is a valid UTF-8 slice
/// Post: result = val matches one of the supported date formats:
///         YYYY-MM-DD  (ISO 8601)
///         DD-MM-YYYY  (European dash)
///         DD/MM/YYYY  (European slash — D1 may be > 12)
///         MM/DD/YYYY  (American slash — D2 may be > 12)
///       Slash formats are accepted regardless of which component is day vs month;
///       the caller resolves ambiguity at the column level (see inferTypes).
///       Basic range checks: month 01-12, day 01-31.
pub fn isDate(val: []const u8) bool {
    if (val.len != 10) return false;
    if (val[4] == '-' and val[7] == '-') {
        // YYYY-MM-DD
        for ([_]usize{ 0, 1, 2, 3, 5, 6, 8, 9 }) |i| if (!std.ascii.isDigit(val[i])) return false;
        const month: u8 = (val[5] - '0') * 10 + (val[6] - '0');
        const day: u8 = (val[8] - '0') * 10 + (val[9] - '0');
        return month >= 1 and month <= 12 and day >= 1 and day <= 31;
    }
    if (val[2] == '-' and val[5] == '-') {
        // DD-MM-YYYY (European dash)
        for ([_]usize{ 0, 1, 3, 4, 6, 7, 8, 9 }) |i| if (!std.ascii.isDigit(val[i])) return false;
        const day: u8 = (val[0] - '0') * 10 + (val[1] - '0');
        const month: u8 = (val[3] - '0') * 10 + (val[4] - '0');
        return month >= 1 and month <= 12 and day >= 1 and day <= 31;
    }
    if (val[2] == '/' and val[5] == '/') {
        // DD/MM/YYYY or MM/DD/YYYY (slash format — ambiguity resolved at column level)
        for ([_]usize{ 0, 1, 3, 4, 6, 7, 8, 9 }) |i| if (!std.ascii.isDigit(val[i])) return false;
        const d1: u8 = (val[0] - '0') * 10 + (val[1] - '0');
        const d2: u8 = (val[3] - '0') * 10 + (val[4] - '0');
        if (d1 == 0 or d1 > 31) return false;
        if (d2 == 0 or d2 > 31) return false;
        return d1 <= 12 or d2 <= 12; // at least one must be a valid month
    }
    return false;
}

/// isDateTime(val) → bool
/// Pre:  val is a valid UTF-8 slice
/// Post: result = val matches one of the supported datetime formats:
///         YYYY-MM-DD HH:MM:SS   (ISO 8601 with space separator, 19 chars)
///         YYYY-MM-DDTHH:MM:SS   (ISO 8601 with T separator, 19 chars)
///         DD/MM/YYYY HH:MM      (European slash, 16 chars)
///         MM/DD/YYYY HH:MM      (American slash, 16 chars)
///       Slash formats: D1/D2 ambiguity resolved at column level (see inferTypes).
///       Range checks: month 01-12, day 01-31, hour 00-23, min 00-59, sec 00-59.
pub fn isDateTime(val: []const u8) bool {
    if (val.len == 19) {
        // YYYY-MM-DD[T ]HH:MM:SS
        if (val[4] != '-' or val[7] != '-') return false;
        if (val[10] != ' ' and val[10] != 'T') return false;
        if (val[13] != ':' or val[16] != ':') return false;
        for ([_]usize{ 0, 1, 2, 3, 5, 6, 8, 9, 11, 12, 14, 15, 17, 18 }) |i|
            if (!std.ascii.isDigit(val[i])) return false;
        const month: u8 = (val[5] - '0') * 10 + (val[6] - '0');
        const day: u8 = (val[8] - '0') * 10 + (val[9] - '0');
        const hour: u8 = (val[11] - '0') * 10 + (val[12] - '0');
        const min: u8 = (val[14] - '0') * 10 + (val[15] - '0');
        const sec: u8 = (val[17] - '0') * 10 + (val[18] - '0');
        return month >= 1 and month <= 12 and day >= 1 and day <= 31 and
            hour <= 23 and min <= 59 and sec <= 59;
    }
    if (val.len == 16) {
        // DD/MM/YYYY HH:MM or MM/DD/YYYY HH:MM
        if (val[2] != '/' or val[5] != '/') return false;
        if (val[10] != ' ' or val[13] != ':') return false;
        for ([_]usize{ 0, 1, 3, 4, 6, 7, 8, 9, 11, 12, 14, 15 }) |i|
            if (!std.ascii.isDigit(val[i])) return false;
        const d1: u8 = (val[0] - '0') * 10 + (val[1] - '0');
        const d2: u8 = (val[3] - '0') * 10 + (val[4] - '0');
        if (d1 == 0 or d1 > 31) return false;
        if (d2 == 0 or d2 > 31) return false;
        if (d1 > 12 and d2 > 12) return false; // no valid month
        const hour: u8 = (val[11] - '0') * 10 + (val[12] - '0');
        const min: u8 = (val[14] - '0') * 10 + (val[15] - '0');
        return hour <= 23 and min <= 59;
    }
    return false;
}

/// Slash-format day/month order for a date or datetime column.
/// Accumulated per-column during type inference to disambiguate DD/MM vs MM/DD.
const SlashOrder = enum { unknown, eu, us, contradictory };

/// accumSlashOrder(current, vote) → SlashOrder
/// Merge a new vote into the running slash-order state for a column.
/// `.unknown` votes (ambiguous value, both components ≤ 12) are ignored.
fn accumSlashOrder(current: SlashOrder, vote: SlashOrder) SlashOrder {
    if (vote == .unknown) return current;
    return switch (current) {
        .unknown => vote,
        .eu => if (vote == .eu) .eu else .contradictory,
        .us => if (vote == .us) .us else .contradictory,
        .contradictory => .contradictory,
    };
}

/// inferTypes(buffer, num_cols, allocator) → []ColumnType
/// Pre:  buffer is a slice of rows (each row is a slice of field strings)
///       num_cols > 0; allocator is valid
/// Post: result.len = num_cols; result[j] is the most specific type that
///       accommodates all non-empty values in column j:
///         DATETIME / DATETIME_EU / DATETIME_US  — all values are datetime strings
///         DATE / DATE_EU / DATE_US              — all values are date strings (no datetime)
///         INTEGER                               — all values are plain integers
///         REAL                                  — all values are numeric (at least one is non-integer)
///         TEXT                                  — any non-numeric/non-date value, or no data,
///                                                 or ambiguous/contradictory slash format
///
/// Slash-format disambiguation: for DD/MM/YYYY and MM/DD/YYYY, values with
/// D1 > 12 vote EU; values with D2 > 12 vote US; both ≤ 12 abstain.
/// Contradictory votes or all-abstain → TEXT.
///
/// Datetime/date priority: isDateTime is checked before isDate; columns with
/// mixed datetime+date values or mixed ISO+slash formats fall back to TEXT.
pub fn inferTypes(
    allocator: std.mem.Allocator,
    buffer: []const [][]u8,
    num_cols: usize,
) std.mem.Allocator.Error![]ColumnType {
    const types = try allocator.alloc(ColumnType, num_cols);
    errdefer allocator.free(types);

    // Numeric tracking (existing)
    const can_be_integer = try allocator.alloc(bool, num_cols);
    defer allocator.free(can_be_integer);
    const can_be_real = try allocator.alloc(bool, num_cols);
    defer allocator.free(can_be_real);
    const has_data = try allocator.alloc(bool, num_cols);
    defer allocator.free(has_data);

    // Datetime tracking
    const can_be_datetime = try allocator.alloc(bool, num_cols);
    defer allocator.free(can_be_datetime);
    const dt_has_iso = try allocator.alloc(bool, num_cols); // 19-char ISO datetime values seen
    defer allocator.free(dt_has_iso);
    const dt_has_slash = try allocator.alloc(bool, num_cols); // 16-char slash datetime values seen
    defer allocator.free(dt_has_slash);
    const slash_order_dt = try allocator.alloc(SlashOrder, num_cols);
    defer allocator.free(slash_order_dt);

    // Date tracking
    const can_be_date = try allocator.alloc(bool, num_cols);
    defer allocator.free(can_be_date);
    const d_has_nonslash = try allocator.alloc(bool, num_cols); // YYYY-MM-DD or DD-MM-YYYY seen
    defer allocator.free(d_has_nonslash);
    const d_has_slash = try allocator.alloc(bool, num_cols); // D1/D2/YYYY slash values seen
    defer allocator.free(d_has_slash);
    const slash_order_d = try allocator.alloc(SlashOrder, num_cols);
    defer allocator.free(slash_order_d);

    for (0..num_cols) |j| {
        can_be_integer[j] = true;
        can_be_real[j] = true;
        has_data[j] = false;
        can_be_datetime[j] = true;
        dt_has_iso[j] = false;
        dt_has_slash[j] = false;
        slash_order_dt[j] = .unknown;
        can_be_date[j] = true;
        d_has_nonslash[j] = false;
        d_has_slash[j] = false;
        slash_order_d[j] = .unknown;
    }

    // Loop invariant I: for each j in 0..num_cols and each value seen so far,
    //   can_be_datetime[j] = true  ⟺  all non-empty values pass isDateTime
    //   can_be_date[j]     = true  ⟺  all non-empty values pass isDate and not isDateTime
    //   can_be_integer[j]  = true  ⟺  all non-empty values are integers
    //   can_be_real[j]     = true  ⟺  all non-empty values are numeric
    //   has_data[j]        = true  ⟺  at least one non-empty value has been seen
    // Bounding function: buffer.len - row_idx
    for (buffer) |row| {
        for (row, 0..) |val, j| {
            if (j >= num_cols) break;
            if (val.len == 0) continue;
            has_data[j] = true;

            // ── Datetime check (highest priority) ────────────────────────────
            if (can_be_datetime[j]) {
                if (!isDateTime(val)) {
                    can_be_datetime[j] = false;
                } else if (val.len == 16) {
                    // Slash datetime: accumulate D1/D2 order vote
                    dt_has_slash[j] = true;
                    const d1: u8 = (val[0] - '0') * 10 + (val[1] - '0');
                    const d2: u8 = (val[3] - '0') * 10 + (val[4] - '0');
                    const vote: SlashOrder = if (d1 > 12) .eu else if (d2 > 12) .us else .unknown;
                    slash_order_dt[j] = accumSlashOrder(slash_order_dt[j], vote);
                } else {
                    dt_has_iso[j] = true;
                }
            }

            // ── Date check (isDate is length-10 only; no overlap with isDateTime) ──
            if (can_be_date[j]) {
                if (!isDate(val)) {
                    can_be_date[j] = false;
                } else if (val[2] == '/') {
                    // Slash date: accumulate D1/D2 order vote
                    d_has_slash[j] = true;
                    const d1: u8 = (val[0] - '0') * 10 + (val[1] - '0');
                    const d2: u8 = (val[3] - '0') * 10 + (val[4] - '0');
                    const vote: SlashOrder = if (d1 > 12) .eu else if (d2 > 12) .us else .unknown;
                    slash_order_d[j] = accumSlashOrder(slash_order_d[j], vote);
                } else {
                    d_has_nonslash[j] = true; // YYYY-MM-DD or DD-MM-YYYY
                }
            }

            // ── Numeric check ────────────────────────────────────────────────
            if (!can_be_real[j]) continue;
            if (!isReal(val)) {
                can_be_real[j] = false;
                can_be_integer[j] = false;
            } else if (!isInteger(val)) {
                can_be_integer[j] = false;
            }
        }
    }

    // Determine final type per column (DATETIME > DATE > INTEGER > REAL > TEXT)
    for (0..num_cols) |j| {
        if (!has_data[j]) {
            types[j] = .TEXT;
        } else if (can_be_datetime[j]) {
            if (dt_has_iso[j] and dt_has_slash[j]) {
                types[j] = .TEXT; // mixed ISO + slash datetime formats
            } else if (dt_has_slash[j]) {
                types[j] = switch (slash_order_dt[j]) {
                    .eu => .DATETIME_EU,
                    .us => .DATETIME_US,
                    else => .TEXT, // unknown (all ambiguous) or contradictory
                };
            } else {
                types[j] = .DATETIME; // pure ISO datetime
            }
        } else if (can_be_date[j]) {
            if (d_has_nonslash[j] and d_has_slash[j]) {
                types[j] = .TEXT; // mixed ISO/dash + slash date formats
            } else if (d_has_slash[j]) {
                types[j] = switch (slash_order_d[j]) {
                    .eu => .DATE_EU,
                    .us => .DATE_US,
                    else => .TEXT, // unknown (all ambiguous) or contradictory
                };
            } else {
                types[j] = .DATE; // YYYY-MM-DD or DD-MM-YYYY (detected at bind time)
            }
        } else if (can_be_integer[j]) {
            types[j] = .INTEGER;
        } else if (can_be_real[j]) {
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

/// insertRowTyped(stmt, row, types, param_count) → void
/// Pre:  stmt is a prepared INSERT with param_count parameters, freshly reset
///       row is a non-empty CSV record (slice of field slices)
///       types.len = param_count (or shorter → remaining treated as TEXT)
/// Post: each field is bound to its parameter using the appropriate SQLite bind
pub fn insertRowTyped(
    stmt: *c.sqlite3_stmt,
    row: [][]u8,
    types: []const ColumnType,
    param_count: c_int,
) args_mod.SqlPipeError!void {
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
            .DATE, .DATE_EU, .DATE_US => {
                // Normalize to ISO 8601 YYYY-MM-DD in a stack buffer.
                // Use SQLITE_TRANSIENT so SQLite copies the value before the buffer
                // is reclaimed (the step happens after this function's stack frame).
                var buf: [10]u8 = undefined;
                const iso = normalizeDateToIso(col_type, val, &buf);
                if (c.sqlite3_bind_text(stmt, col_idx, iso.ptr, @intCast(iso.len), sqlite_mod.sqliteTransient()) != c.SQLITE_OK)
                    return error.BindFailed;
            },
            .DATETIME, .DATETIME_EU, .DATETIME_US => {
                var buf: [19]u8 = undefined;
                const iso = normalizeDateTimeToIso(col_type, val, &buf);
                if (c.sqlite3_bind_text(stmt, col_idx, iso.ptr, @intCast(iso.len), sqlite_mod.sqliteTransient()) != c.SQLITE_OK)
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

/// normalizeDateToIso(col_type, val, buf) → []const u8
/// Pre:  col_type ∈ {DATE, DATE_EU, DATE_US}
///       val was accepted by isDate during type inference; val.len == 10
///       buf.len >= 10
/// Post: result is buf[0..10] formatted as "YYYY-MM-DD" (ISO 8601)
///       DATE with val[4]=='-': YYYY-MM-DD passthrough
///       DATE with val[2]=='-': DD-MM-YYYY → YYYY-MM-DD
///       DATE_EU: DD/MM/YYYY → YYYY-MM-DD
///       DATE_US: MM/DD/YYYY → YYYY-MM-DD
fn normalizeDateToIso(col_type: ColumnType, val: []const u8, buf: *[10]u8) []const u8 {
    switch (col_type) {
        .DATE => {
            if (val[4] == '-') {
                // YYYY-MM-DD — already ISO, copy as-is
                @memcpy(buf, val[0..10]);
            } else {
                // DD-MM-YYYY → YYYY-MM-DD
                buf[0] = val[6]; buf[1] = val[7]; buf[2] = val[8]; buf[3] = val[9];
                buf[4] = '-';
                buf[5] = val[3]; buf[6] = val[4];
                buf[7] = '-';
                buf[8] = val[0]; buf[9] = val[1];
            }
        },
        .DATE_EU => {
            // DD/MM/YYYY → YYYY-MM-DD
            buf[0] = val[6]; buf[1] = val[7]; buf[2] = val[8]; buf[3] = val[9];
            buf[4] = '-';
            buf[5] = val[3]; buf[6] = val[4];
            buf[7] = '-';
            buf[8] = val[0]; buf[9] = val[1];
        },
        .DATE_US => {
            // MM/DD/YYYY → YYYY-MM-DD
            buf[0] = val[6]; buf[1] = val[7]; buf[2] = val[8]; buf[3] = val[9];
            buf[4] = '-';
            buf[5] = val[0]; buf[6] = val[1];
            buf[7] = '-';
            buf[8] = val[3]; buf[9] = val[4];
        },
        else => unreachable,
    }
    return buf[0..10];
}

/// normalizeDateTimeToIso(col_type, val, buf) → []const u8
/// Pre:  col_type ∈ {DATETIME, DATETIME_EU, DATETIME_US}
///       val was accepted by isDateTime during type inference
///       buf.len >= 19
/// Post: result is buf[0..19] formatted as "YYYY-MM-DD HH:MM:SS" (ISO 8601 with space)
///       DATETIME: T-separator normalized to space; space-separator passed through
///       DATETIME_EU: DD/MM/YYYY HH:MM → YYYY-MM-DD HH:MM:00
///       DATETIME_US: MM/DD/YYYY HH:MM → YYYY-MM-DD HH:MM:00
fn normalizeDateTimeToIso(col_type: ColumnType, val: []const u8, buf: *[19]u8) []const u8 {
    switch (col_type) {
        .DATETIME => {
            // YYYY-MM-DD[T ]HH:MM:SS → YYYY-MM-DD HH:MM:SS
            @memcpy(buf, val[0..19]);
            buf[10] = ' '; // normalize T → space (no-op when already space)
        },
        .DATETIME_EU => {
            // DD/MM/YYYY HH:MM → YYYY-MM-DD HH:MM:00
            buf[0] = val[6]; buf[1] = val[7]; buf[2] = val[8]; buf[3] = val[9];
            buf[4] = '-';
            buf[5] = val[3]; buf[6] = val[4];
            buf[7] = '-';
            buf[8] = val[0]; buf[9] = val[1];
            buf[10] = ' ';
            buf[11] = val[11]; buf[12] = val[12];
            buf[13] = ':';
            buf[14] = val[14]; buf[15] = val[15];
            buf[16] = ':'; buf[17] = '0'; buf[18] = '0';
        },
        .DATETIME_US => {
            // MM/DD/YYYY HH:MM → YYYY-MM-DD HH:MM:00
            buf[0] = val[6]; buf[1] = val[7]; buf[2] = val[8]; buf[3] = val[9];
            buf[4] = '-';
            buf[5] = val[0]; buf[6] = val[1];
            buf[7] = '-';
            buf[8] = val[3]; buf[9] = val[4];
            buf[10] = ' ';
            buf[11] = val[11]; buf[12] = val[12];
            buf[13] = ':';
            buf[14] = val[14]; buf[15] = val[15];
            buf[16] = ':'; buf[17] = '0'; buf[18] = '0';
        },
        else => unreachable,
    }
    return buf[0..19];
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

    sqlite_mod.beginTransaction(db, stderr_writer);

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
        insertRowTyped(stmt, row, types, @intCast(num_cols)) catch
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
        insertRowTyped(stmt, record, types, @intCast(num_cols)) catch
            fatalSqlWithContext(allocator, db, std.mem.span(c.sqlite3_errmsg(db)), stderr_writer);
        if (is_tty and rows_inserted % progress_interval == 0)
            printProgress(stderr_writer, rows_inserted, parsed.max_rows);
    }

    sqlite_mod.commitTransaction(db, stderr_writer);

    return rows_inserted;
}

// ─── Unit tests ───────────────────────────────────────

test "isDate: valid ISO dates" {
    try std.testing.expect(isDate("2024-01-15"));
    try std.testing.expect(isDate("1999-12-31"));
    try std.testing.expect(isDate("2000-02-29")); // range check only — calendar validity not enforced
}

test "isDate: valid EU dash dates" {
    try std.testing.expect(isDate("15-01-2024"));
    try std.testing.expect(isDate("31-12-1999"));
}

test "isDate: valid slash dates" {
    try std.testing.expect(isDate("15/01/2024")); // EU slash (d1=15 > 12)
    try std.testing.expect(isDate("01/15/2024")); // US slash (d2=15 > 12)
    try std.testing.expect(isDate("05/06/2024")); // ambiguous (both ≤ 12)
}

test "isDate: invalid inputs" {
    try std.testing.expect(!isDate(""));
    try std.testing.expect(!isDate("2024-1-15")); // single-digit month
    try std.testing.expect(!isDate("not-a-date"));
    try std.testing.expect(!isDate("2024-00-15")); // month 0
    try std.testing.expect(!isDate("2024-13-01")); // month 13
    try std.testing.expect(!isDate("2024-01-00")); // day 0
    try std.testing.expect(!isDate("2024-01-32")); // day 32
    try std.testing.expect(!isDate("20240115")); // no separators
    try std.testing.expect(!isDate("2024/01/15")); // YYYY/MM/DD not supported
    try std.testing.expect(!isDate("13/13/2024")); // both > 12, no valid month
}

test "isDate does not match datetimes" {
    // datetime values are 16 or 19 chars; isDate is length-gated to 10
    try std.testing.expect(!isDate("2024-01-15 10:30:00"));
    try std.testing.expect(!isDate("2024-01-15T10:30:00"));
    try std.testing.expect(!isDate("15/01/2024 10:30"));
}

test "isDateTime: valid ISO datetimes" {
    try std.testing.expect(isDateTime("2024-01-15 10:30:00"));
    try std.testing.expect(isDateTime("2024-01-15T10:30:00"));
    try std.testing.expect(isDateTime("1999-12-31 23:59:59"));
    try std.testing.expect(isDateTime("2000-01-01 00:00:00"));
}

test "isDateTime: valid slash datetimes" {
    try std.testing.expect(isDateTime("15/01/2024 10:30")); // EU (d1=15 > 12)
    try std.testing.expect(isDateTime("01/15/2024 10:30")); // US (d2=15 > 12)
    try std.testing.expect(isDateTime("05/06/2024 08:00")); // ambiguous
}

test "isDateTime: invalid inputs" {
    try std.testing.expect(!isDateTime(""));
    try std.testing.expect(!isDateTime("2024-01-15 25:00:00")); // hour 25
    try std.testing.expect(!isDateTime("2024-01-15 10:60:00")); // min 60
    try std.testing.expect(!isDateTime("2024-01-15 10:30:60")); // sec 60
    try std.testing.expect(!isDateTime("2024-13-15 10:30:00")); // month 13
    try std.testing.expect(!isDateTime("13/13/2024 10:30")); // both > 12, no valid month
    try std.testing.expect(!isDateTime("2024-01-15")); // date only, length 10
    try std.testing.expect(!isDateTime("not-a-datetime"));
}

test "accumSlashOrder: merging votes" {
    try std.testing.expectEqual(SlashOrder.eu, accumSlashOrder(.unknown, .eu));
    try std.testing.expectEqual(SlashOrder.us, accumSlashOrder(.unknown, .us));
    try std.testing.expectEqual(SlashOrder.eu, accumSlashOrder(.eu, .eu));
    try std.testing.expectEqual(SlashOrder.us, accumSlashOrder(.us, .us));
    try std.testing.expectEqual(SlashOrder.unknown, accumSlashOrder(.unknown, .unknown));
    try std.testing.expectEqual(SlashOrder.eu, accumSlashOrder(.eu, .unknown));
    try std.testing.expectEqual(SlashOrder.us, accumSlashOrder(.us, .unknown));
    try std.testing.expectEqual(SlashOrder.contradictory, accumSlashOrder(.eu, .us));
    try std.testing.expectEqual(SlashOrder.contradictory, accumSlashOrder(.us, .eu));
    try std.testing.expectEqual(SlashOrder.contradictory, accumSlashOrder(.contradictory, .eu));
}

test "normalizeDateToIso: ISO passthrough" {
    var buf: [10]u8 = undefined;
    const result = normalizeDateToIso(.DATE, "2024-01-15", &buf);
    try std.testing.expectEqualStrings("2024-01-15", result);
}

test "normalizeDateToIso: EU dash to ISO" {
    var buf: [10]u8 = undefined;
    const result = normalizeDateToIso(.DATE, "15-01-2024", &buf);
    try std.testing.expectEqualStrings("2024-01-15", result);
}

test "normalizeDateToIso: EU slash to ISO" {
    var buf: [10]u8 = undefined;
    const result = normalizeDateToIso(.DATE_EU, "15/01/2024", &buf);
    try std.testing.expectEqualStrings("2024-01-15", result);
}

test "normalizeDateToIso: US slash to ISO" {
    var buf: [10]u8 = undefined;
    const result = normalizeDateToIso(.DATE_US, "01/15/2024", &buf);
    try std.testing.expectEqualStrings("2024-01-15", result);
}

test "normalizeDateTimeToIso: ISO T-separator normalized to space" {
    var buf: [19]u8 = undefined;
    const result = normalizeDateTimeToIso(.DATETIME, "2024-01-15T10:30:00", &buf);
    try std.testing.expectEqualStrings("2024-01-15 10:30:00", result);
}

test "normalizeDateTimeToIso: ISO space-separator passthrough" {
    var buf: [19]u8 = undefined;
    const result = normalizeDateTimeToIso(.DATETIME, "2024-01-15 10:30:00", &buf);
    try std.testing.expectEqualStrings("2024-01-15 10:30:00", result);
}

test "normalizeDateTimeToIso: EU slash to ISO" {
    var buf: [19]u8 = undefined;
    const result = normalizeDateTimeToIso(.DATETIME_EU, "15/01/2024 10:30", &buf);
    try std.testing.expectEqualStrings("2024-01-15 10:30:00", result);
}

test "normalizeDateTimeToIso: US slash to ISO" {
    var buf: [19]u8 = undefined;
    const result = normalizeDateTimeToIso(.DATETIME_US, "01/15/2024 10:30", &buf);
    try std.testing.expectEqualStrings("2024-01-15 10:30:00", result);
}

test "inferTypes: empty buffer → all TEXT" {
    const allocator = std.testing.allocator;
    const buffer: []const [][]u8 = &.{};
    const types = try inferTypes(allocator, buffer, 3);
    defer allocator.free(types);
    try std.testing.expectEqual(ColumnType.TEXT, types[0]);
    try std.testing.expectEqual(ColumnType.TEXT, types[1]);
    try std.testing.expectEqual(ColumnType.TEXT, types[2]);
}

test "inferTypes: detects INTEGER" {
    const allocator = std.testing.allocator;
    var f1: [2][]u8 = .{ @constCast("42"), @constCast("hello") };
    var f2: [2][]u8 = .{ @constCast("-7"), @constCast("world") };
    const rows: []const [][]u8 = &.{ &f1, &f2 };
    const types = try inferTypes(allocator, rows, 2);
    defer allocator.free(types);
    try std.testing.expectEqual(ColumnType.INTEGER, types[0]);
    try std.testing.expectEqual(ColumnType.TEXT, types[1]);
}

test "inferTypes: detects REAL" {
    const allocator = std.testing.allocator;
    var f1: [1][]u8 = .{@constCast("3.14")};
    const rows: []const [][]u8 = &.{&f1};
    const types = try inferTypes(allocator, rows, 1);
    defer allocator.free(types);
    try std.testing.expectEqual(ColumnType.REAL, types[0]);
}

test "inferTypes: detects DATE (ISO YYYY-MM-DD)" {
    const allocator = std.testing.allocator;
    var f1: [1][]u8 = .{@constCast("2024-01-15")};
    var f2: [1][]u8 = .{@constCast("1999-12-31")};
    const rows: []const [][]u8 = &.{ &f1, &f2 };
    const types = try inferTypes(allocator, rows, 1);
    defer allocator.free(types);
    try std.testing.expectEqual(ColumnType.DATE, types[0]);
}

test "inferTypes: detects DATE_EU (slash with d1 > 12)" {
    const allocator = std.testing.allocator;
    var f1: [1][]u8 = .{@constCast("15/01/2024")};
    const rows: []const [][]u8 = &.{&f1};
    const types = try inferTypes(allocator, rows, 1);
    defer allocator.free(types);
    try std.testing.expectEqual(ColumnType.DATE_EU, types[0]);
}

test "inferTypes: detects DATE_US (slash with d2 > 12)" {
    const allocator = std.testing.allocator;
    var f1: [1][]u8 = .{@constCast("01/15/2024")};
    const rows: []const [][]u8 = &.{&f1};
    const types = try inferTypes(allocator, rows, 1);
    defer allocator.free(types);
    try std.testing.expectEqual(ColumnType.DATE_US, types[0]);
}

test "inferTypes: ambiguous slash date → TEXT" {
    const allocator = std.testing.allocator;
    var f1: [1][]u8 = .{@constCast("05/06/2024")};
    const rows: []const [][]u8 = &.{&f1};
    const types = try inferTypes(allocator, rows, 1);
    defer allocator.free(types);
    try std.testing.expectEqual(ColumnType.TEXT, types[0]);
}

test "inferTypes: contradictory slash votes → TEXT" {
    const allocator = std.testing.allocator;
    var f1: [1][]u8 = .{@constCast("15/01/2024")}; // EU vote (d1=15 > 12)
    var f2: [1][]u8 = .{@constCast("01/15/2024")}; // US vote (d2=15 > 12)
    const rows: []const [][]u8 = &.{ &f1, &f2 };
    const types = try inferTypes(allocator, rows, 1);
    defer allocator.free(types);
    try std.testing.expectEqual(ColumnType.TEXT, types[0]);
}

test "inferTypes: detects DATETIME (ISO space)" {
    const allocator = std.testing.allocator;
    var f1: [1][]u8 = .{@constCast("2024-01-15 10:30:00")};
    const rows: []const [][]u8 = &.{&f1};
    const types = try inferTypes(allocator, rows, 1);
    defer allocator.free(types);
    try std.testing.expectEqual(ColumnType.DATETIME, types[0]);
}

test "inferTypes: detects DATETIME (ISO T-separator)" {
    const allocator = std.testing.allocator;
    var f1: [1][]u8 = .{@constCast("2024-01-15T10:30:00")};
    const rows: []const [][]u8 = &.{&f1};
    const types = try inferTypes(allocator, rows, 1);
    defer allocator.free(types);
    try std.testing.expectEqual(ColumnType.DATETIME, types[0]);
}

test "inferTypes: DATETIME beats DATE — datetime column stays DATETIME" {
    const allocator = std.testing.allocator;
    var f1: [1][]u8 = .{@constCast("2024-01-15T10:30:00")};
    var f2: [1][]u8 = .{@constCast("1999-12-31 23:59:59")};
    const rows: []const [][]u8 = &.{ &f1, &f2 };
    const types = try inferTypes(allocator, rows, 1);
    defer allocator.free(types);
    try std.testing.expectEqual(ColumnType.DATETIME, types[0]);
}

test "inferTypes: mixed date and datetime → TEXT" {
    const allocator = std.testing.allocator;
    var f1: [1][]u8 = .{@constCast("2024-01-15")};
    var f2: [1][]u8 = .{@constCast("2024-01-16 10:30:00")};
    const rows: []const [][]u8 = &.{ &f1, &f2 };
    const types = try inferTypes(allocator, rows, 1);
    defer allocator.free(types);
    try std.testing.expectEqual(ColumnType.TEXT, types[0]);
}

test "inferTypes: mixed ISO and slash datetime → TEXT" {
    const allocator = std.testing.allocator;
    var f1: [1][]u8 = .{@constCast("2024-01-15 10:30:00")}; // ISO datetime
    var f2: [1][]u8 = .{@constCast("15/01/2024 10:30")}; // EU slash datetime
    const rows: []const [][]u8 = &.{ &f1, &f2 };
    const types = try inferTypes(allocator, rows, 1);
    defer allocator.free(types);
    try std.testing.expectEqual(ColumnType.TEXT, types[0]);
}

test "inferTypes: empty values ignored in type inference" {
    const allocator = std.testing.allocator;
    var f1: [1][]u8 = .{@constCast("")}; // empty → skip
    var f2: [1][]u8 = .{@constCast("2024-01-15")};
    const rows: []const [][]u8 = &.{ &f1, &f2 };
    const types = try inferTypes(allocator, rows, 1);
    defer allocator.free(types);
    try std.testing.expectEqual(ColumnType.DATE, types[0]);
}

test "inferTypes: detects DATE (EU-dash DD-MM-YYYY)" {
    const allocator = std.testing.allocator;
    var f1: [1][]u8 = .{@constCast("15-01-2024")};
    var f2: [1][]u8 = .{@constCast("31-12-1999")};
    const rows: []const [][]u8 = &.{ &f1, &f2 };
    const types = try inferTypes(allocator, rows, 1);
    defer allocator.free(types);
    try std.testing.expectEqual(ColumnType.DATE, types[0]);
}

test "inferTypes: mixed ISO and EU-dash dates → DATE" {
    // Both YYYY-MM-DD and DD-MM-YYYY are non-slash; both infer to .DATE.
    // bind-time detection distinguishes them via val[4]=='-'.
    const allocator = std.testing.allocator;
    var f1: [1][]u8 = .{@constCast("2024-01-15")}; // ISO
    var f2: [1][]u8 = .{@constCast("15-01-2024")}; // EU dash
    const rows: []const [][]u8 = &.{ &f1, &f2 };
    const types = try inferTypes(allocator, rows, 1);
    defer allocator.free(types);
    try std.testing.expectEqual(ColumnType.DATE, types[0]);
}

test "inferTypes: detects DATETIME_EU (slash datetime with d1 > 12)" {
    const allocator = std.testing.allocator;
    var f1: [1][]u8 = .{@constCast("15/01/2024 10:30")};
    const rows: []const [][]u8 = &.{&f1};
    const types = try inferTypes(allocator, rows, 1);
    defer allocator.free(types);
    try std.testing.expectEqual(ColumnType.DATETIME_EU, types[0]);
}

test "inferTypes: detects DATETIME_US (slash datetime with d2 > 12)" {
    const allocator = std.testing.allocator;
    var f1: [1][]u8 = .{@constCast("01/15/2024 10:30")};
    const rows: []const [][]u8 = &.{&f1};
    const types = try inferTypes(allocator, rows, 1);
    defer allocator.free(types);
    try std.testing.expectEqual(ColumnType.DATETIME_US, types[0]);
}

test "inferTypes: mixed ISO date and slash date → TEXT (d_has_nonslash && d_has_slash)" {
    // Exercises loader.zig line 287: d_has_nonslash[j] and d_has_slash[j] → TEXT
    const allocator = std.testing.allocator;
    var f1: [1][]u8 = .{@constCast("2024-01-15")}; // ISO → d_has_nonslash
    var f2: [1][]u8 = .{@constCast("15/01/2024")}; // EU slash → d_has_slash
    const rows: []const [][]u8 = &.{ &f1, &f2 };
    const types = try inferTypes(allocator, rows, 1);
    defer allocator.free(types);
    try std.testing.expectEqual(ColumnType.TEXT, types[0]);
}
