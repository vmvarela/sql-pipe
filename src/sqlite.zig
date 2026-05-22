//! Shared SQLite helper functions used by all input format loaders.

const std = @import("std");
const c = @import("c");
const args_mod = @import("args.zig");

pub const ExitCode = args_mod.ExitCode;

/// SQLITE_STATIC: caller manages string lifetime; SQLite must not free it.
pub const sqlite_static: c.sqlite3_destructor_type = null;

/// Returns the SQLITE_TRANSIENT sentinel (-1 cast to destructor type).
/// Defined as a function to force runtime evaluation: `const` locals are
/// comptime-known in Zig and would trigger a compile-time alignment error;
/// `var` makes `addr` runtime-unknown, so @ptrFromInt does a runtime check
/// that we suppress with @setRuntimeSafety(false).
/// SQLite checks this value by comparison, not by calling it, so the
/// misalignment is harmless at runtime.
pub fn sqliteTransient() c.sqlite3_destructor_type {
    @setRuntimeSafety(false);
    var addr: usize = @bitCast(@as(isize, -1));
    _ = &addr; // prevent constant-folding
    return @ptrFromInt(addr);
}

/// Inferred SQLite column type for a CSV column.
///
/// DATE and DATETIME variants track the source format for normalization at
/// insert time. All DATE* variants map to TEXT affinity in DDL (SQLite stores
/// dates as ISO 8601 text). displayName() returns "DATE" or "DATETIME" for
/// user-facing output regardless of sub-variant.
///
/// Sub-variant semantics:
///   DATE        — YYYY-MM-DD or DD-MM-YYYY (format detected at bind time by separator position)
///   DATE_EU     — DD/MM/YYYY (European slash; D1 > 12 was found during inference)
///   DATE_US     — MM/DD/YYYY (American slash; D2 > 12 was found during inference)
///   DATETIME    — YYYY-MM-DD HH:MM:SS or YYYY-MM-DDTHH:MM:SS (19-char ISO)
///   DATETIME_EU — DD/MM/YYYY HH:MM (16-char European slash)
///   DATETIME_US — MM/DD/YYYY HH:MM (16-char American slash)
pub const ColumnType = enum {
    TEXT,
    INTEGER,
    REAL,
    DATE,
    DATE_EU,
    DATE_US,
    DATETIME,
    DATETIME_EU,
    DATETIME_US,

    /// User-facing name used in --validate, --columns --verbose, and --sample output.
    /// All DATE* variants display as "DATE"; all DATETIME* as "DATETIME".
    pub fn displayName(self: ColumnType) []const u8 {
        return switch (self) {
            .TEXT => "TEXT",
            .INTEGER => "INTEGER",
            .REAL => "REAL",
            .DATE, .DATE_EU, .DATE_US => "DATE",
            .DATETIME, .DATETIME_EU, .DATETIME_US => "DATETIME",
        };
    }
};

/// fatal(fmt, writer, code, args) → noreturn
///
/// Writes an error message to writer and exits with the given code.
pub fn fatal(comptime fmt: []const u8, writer: *std.Io.Writer, code: ExitCode, args: anytype) noreturn {
    writer.print("error: " ++ fmt ++ "\n", args) catch |err| std.log.err("failed to write error: {}", .{err});
    writer.flush() catch |err| std.log.err("failed to flush: {}", .{err});
    std.process.exit(@intFromEnum(code));
}

/// Create table `t` with all-TEXT columns. Column names are double-quote–escaped
/// per SQL identifier rules.
pub fn createAllTextTable(
    allocator: std.mem.Allocator,
    db: *c.sqlite3,
    cols: []const []const u8,
    writer: *std.Io.Writer,
) void {
    var sql: std.ArrayList(u8) = .empty;
    defer sql.deinit(allocator);

    sql.appendSlice(allocator, "CREATE TABLE t (") catch fatal("out of memory", writer, .csv_error, .{});
    for (cols, 0..) |col, i| {
        if (i > 0) sql.appendSlice(allocator, ", ") catch fatal("out of memory", writer, .csv_error, .{});
        sql.append(allocator, '"') catch fatal("out of memory", writer, .csv_error, .{});
        for (col) |ch| {
            if (ch == '"') sql.append(allocator, '"') catch fatal("out of memory", writer, .csv_error, .{});
            sql.append(allocator, ch) catch fatal("out of memory", writer, .csv_error, .{});
        }
        sql.appendSlice(allocator, "\" TEXT") catch fatal("out of memory", writer, .csv_error, .{});
    }
    sql.appendSlice(allocator, ")") catch fatal("out of memory", writer, .csv_error, .{});
    sql.append(allocator, 0) catch fatal("out of memory", writer, .csv_error, .{});

    var errmsg: [*c]u8 = null;
    if (c.sqlite3_exec(db, sql.items.ptr, null, null, &errmsg) != c.SQLITE_OK) {
        const msg = if (errmsg != null) std.mem.span(errmsg) else std.mem.span(c.sqlite3_errmsg(db));
        if (errmsg != null) c.sqlite3_free(errmsg);
        fatal("{s}", writer, .sql_error, .{msg});
    }
}

/// Prepare `INSERT INTO t VALUES (?, …, ?)` with n parameters.
pub fn prepareInsertStmt(
    allocator: std.mem.Allocator,
    db: *c.sqlite3,
    n: usize,
    writer: *std.Io.Writer,
) *c.sqlite3_stmt {
    var sql: std.ArrayList(u8) = .empty;
    defer sql.deinit(allocator);

    sql.appendSlice(allocator, "INSERT INTO t VALUES (") catch fatal("out of memory", writer, .csv_error, .{});
    for (0..n) |i| {
        if (i > 0) sql.append(allocator, ',') catch fatal("out of memory", writer, .csv_error, .{});
        sql.append(allocator, '?') catch fatal("out of memory", writer, .csv_error, .{});
    }
    sql.appendSlice(allocator, ")") catch fatal("out of memory", writer, .csv_error, .{});
    sql.append(allocator, 0) catch fatal("out of memory", writer, .csv_error, .{});

    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(db, sql.items.ptr, -1, &stmt, null) != c.SQLITE_OK)
        fatal("{s}", writer, .sql_error, .{std.mem.span(c.sqlite3_errmsg(db))});
    return stmt.?;
}

pub fn beginTransaction(db: *c.sqlite3, writer: *std.Io.Writer) void {
    var errmsg: [*c]u8 = null;
    if (c.sqlite3_exec(db, "BEGIN TRANSACTION", null, null, &errmsg) != c.SQLITE_OK) {
        const msg = if (errmsg != null) std.mem.span(errmsg) else std.mem.span(c.sqlite3_errmsg(db));
        if (errmsg != null) c.sqlite3_free(errmsg);
        fatal("{s}", writer, .sql_error, .{msg});
    }
}

pub fn commitTransaction(db: *c.sqlite3, writer: *std.Io.Writer) void {
    var errmsg: [*c]u8 = null;
    if (c.sqlite3_exec(db, "COMMIT", null, null, &errmsg) != c.SQLITE_OK) {
        const msg = if (errmsg != null) std.mem.span(errmsg) else std.mem.span(c.sqlite3_errmsg(db));
        if (errmsg != null) c.sqlite3_free(errmsg);
        fatal("{s}", writer, .sql_error, .{msg});
    }
}

/// openDb(disk, writer) → *sqlite3
/// Pre:  —
/// Post: result is an open, empty SQLite database handle.
///       When disk=false: in-memory database (`:memory:`).
///       When disk=true:  file-backed private temp database (`""`); SQLite
///         creates a temp file and deletes it automatically on close.
///         PRAGMA temp_store = FILE is set so ORDER BY / GROUP BY transient
///         structures also spill to disk rather than RAM.
///         Exits with sql_error if the temp directory is not writable.
pub fn openDb(disk: bool, writer: *std.Io.Writer) *c.sqlite3 {
    var db: ?*c.sqlite3 = null;
    if (!disk) {
        if (c.sqlite3_open(":memory:", &db) != c.SQLITE_OK)
            fatal("failed to open in-memory database", writer, .sql_error, .{});
        return db.?;
    }

    // Empty string → SQLite private temp file, deleted on close.
    if (c.sqlite3_open("", &db) != c.SQLITE_OK) {
        const msg = std.mem.span(c.sqlite3_errmsg(db));
        fatal("failed to open temporary database (is the temp directory writable?): {s}", writer, .sql_error, .{msg});
    }

    // Ensure transient structures (ORDER BY sorts, GROUP BY indices) also spill to disk.
    var errmsg: [*c]u8 = null;
    if (c.sqlite3_exec(db.?, "PRAGMA temp_store = FILE", null, null, &errmsg) != c.SQLITE_OK) {
        const msg = if (errmsg != null) std.mem.span(errmsg) else std.mem.span(c.sqlite3_errmsg(db));
        if (errmsg != null) c.sqlite3_free(errmsg);
        fatal("failed to set PRAGMA temp_store = FILE: {s}", writer, .sql_error, .{msg});
    }

    return db.?;
}

/// createTable(allocator, db, cols, types, writer) → void
/// Pre:  db is an open SQLite handle
///       cols.len > 0
///       types.len = cols.len
///       allocator is valid
/// Post: table `t` exists in db with cols.len columns named by cols;
///       each column's SQL type reflects its ColumnType value
///       (INTEGER / REAL / TEXT with correct SQLite affinity)
///       column identifiers are double-quote escaped per SQL syntax
pub fn createTable(
    allocator: std.mem.Allocator,
    db: *c.sqlite3,
    cols: []const []const u8,
    types: []const ColumnType,
    writer: *std.Io.Writer,
) void {
    var sql: std.ArrayList(u8) = .empty;
    defer sql.deinit(allocator);

    sql.appendSlice(allocator, "CREATE TABLE t (") catch fatal("out of memory", writer, .csv_error, .{});
    for (cols, 0..) |col, i| {
        if (i > 0) sql.appendSlice(allocator, ", ") catch fatal("out of memory", writer, .csv_error, .{});
        sql.append(allocator, '"') catch fatal("out of memory", writer, .csv_error, .{});
        for (col) |ch| {
            if (ch == '"') sql.append(allocator, '"') catch fatal("out of memory", writer, .csv_error, .{});
            sql.append(allocator, ch) catch fatal("out of memory", writer, .csv_error, .{});
        }
        sql.append(allocator, '"') catch fatal("out of memory", writer, .csv_error, .{});
        sql.appendSlice(allocator, switch (types[i]) {
            .INTEGER => " INTEGER",
            .REAL => " REAL",
            .TEXT => " TEXT",
            // DATE* and DATETIME* emit TEXT in DDL to guarantee TEXT affinity.
            // Declaring "DATE" or "DATETIME" would give NUMERIC affinity, which
            // would attempt numeric coercion of ISO 8601 strings. TEXT affinity
            // preserves string semantics and lets all SQLite date functions work.
            .DATE, .DATE_EU, .DATE_US,
            .DATETIME, .DATETIME_EU, .DATETIME_US,
            => " TEXT",
        }) catch fatal("out of memory", writer, .csv_error, .{});
    }
    sql.appendSlice(allocator, ")") catch fatal("out of memory", writer, .csv_error, .{});
    sql.append(allocator, 0) catch fatal("out of memory", writer, .csv_error, .{});

    var errmsg: [*c]u8 = null;
    if (c.sqlite3_exec(db, sql.items.ptr, null, null, &errmsg) != c.SQLITE_OK) {
        const msg = if (errmsg != null) std.mem.span(errmsg) else std.mem.span(c.sqlite3_errmsg(db));
        if (errmsg != null) c.sqlite3_free(errmsg);
        fatal("{s}", writer, .sql_error, .{msg});
    }
}

/// Compute the Levenshtein edit distance between two strings.
/// Uses two-row DP over at most max_len characters per string.
pub fn levenshteinDistance(a: []const u8, b: []const u8) usize {
    const max_len = 128;
    var prev: [max_len + 1]usize = undefined;
    var curr: [max_len + 1]usize = undefined;
    const a_len = @min(a.len, max_len);
    const b_len = @min(b.len, max_len);

    for (0..b_len + 1) |j| prev[j] = j;
    for (0..a_len) |i| {
        curr[0] = i + 1;
        for (0..b_len) |j| {
            const cost: usize = if (a[i] == b[j]) 0 else 1;
            curr[j + 1] = @min(curr[j] + 1, @min(prev[j + 1] + 1, prev[j] + cost));
        }
        @memcpy(prev[0 .. b_len + 1], curr[0 .. b_len + 1]);
    }
    return prev[b_len];
}

/// Return column names of table `t` via PRAGMA table_info.
/// Caller owns the returned slice; free each element and the slice with allocator.
/// Returns empty slice on PRAGMA failure.
pub fn getTableColumns(allocator: std.mem.Allocator, db: *c.sqlite3) ![][]const u8 {
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(db, "PRAGMA table_info(t)", -1, &stmt, null) != c.SQLITE_OK)
        return &.{};
    defer _ = c.sqlite3_finalize(stmt);

    var cols = std.ArrayList([]const u8).empty;
    errdefer {
        for (cols.items) |col| allocator.free(col);
        cols.deinit(allocator);
    }

    while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
        // PRAGMA table_info columns: cid(0), name(1), type(2), notnull(3), dflt_value(4), pk(5)
        const ptr = c.sqlite3_column_text(stmt, 1);
        if (ptr == null) continue;
        const name = std.mem.span(@as([*:0]const u8, @ptrCast(ptr)));
        const owned = try allocator.dupe(u8, name);
        errdefer allocator.free(owned);
        try cols.append(allocator, owned);
    }

    return cols.toOwnedSlice(allocator);
}

/// Print column context to writer after a SQL error.
/// Prints "  table \"t\" has columns: ..." and optionally "  hint: did you mean \"<col>\"?"
/// when the error message matches "no such column: <name>" and a column exists within edit distance 2.
/// Silently returns on any failure (PRAGMA unavailable, OOM, writer error).
pub fn printSqlErrorContext(
    allocator: std.mem.Allocator,
    db: *c.sqlite3,
    errmsg: []const u8,
    writer: *std.Io.Writer,
) void {
    const columns = getTableColumns(allocator, db) catch return;
    defer {
        for (columns) |col| allocator.free(col);
        allocator.free(columns);
    }
    if (columns.len == 0) return;

    writer.writeAll("  table \"t\" has columns: ") catch return;
    for (columns, 0..) |col, i| {
        if (i > 0) writer.writeAll(", ") catch return;
        writer.writeAll(col) catch return;
    }
    writer.writeByte('\n') catch return;

    // Suggest the closest column when the error is "no such column: <name>"
    const no_such_col = "no such column: ";
    if (std.mem.find(u8, errmsg, no_such_col)) |start| {
        const missing = errmsg[start + no_such_col.len ..];
        var best_col: ?[]const u8 = null;
        var best_dist: usize = std.math.maxInt(usize);
        for (columns) |col| {
            const dist = levenshteinDistance(missing, col);
            if (dist < best_dist) {
                best_dist = dist;
                best_col = col;
            }
        }
        if (best_dist <= 2) {
            if (best_col) |col| {
                writer.print("  hint: did you mean \"{s}\"?\n", .{col}) catch return;
            }
        }
    }
}

/// Print SQL error message with column context then exit with sql_error code.
/// Pre:  errmsg is the SQLite error string; db has table `t` (or PRAGMA silently fails)
/// Post: stderr has "error: <msg>\n" + optional column list + optional hint; process exits 3
pub fn fatalSqlWithContext(
    allocator: std.mem.Allocator,
    db: *c.sqlite3,
    errmsg: []const u8,
    writer: *std.Io.Writer,
) noreturn {
    writer.print("error: {s}\n", .{errmsg}) catch |err| {
        std.log.err("failed to write error message: {}", .{err});
    };
    printSqlErrorContext(allocator, db, errmsg, writer);
    writer.flush() catch |err| std.log.err("failed to flush: {}", .{err});
    std.process.exit(@intFromEnum(ExitCode.sql_error));
}
