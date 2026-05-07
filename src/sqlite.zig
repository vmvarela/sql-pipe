//! Shared SQLite helper functions used by all input format loaders.

const std = @import("std");
const c = @import("c");

/// SQLITE_STATIC: caller manages string lifetime; SQLite must not free it.
pub const sqlite_static: c.sqlite3_destructor_type = null;

// Shared exit codes (same values as in each format module)
pub const exit_usage: u8 = 1;
pub const exit_parse: u8 = 2;
pub const exit_sql: u8 = 3;

/// fatal(fmt, writer, code, args) → noreturn
///
/// Writes an error message to writer and exits with the given code.
pub fn fatal(comptime fmt: []const u8, writer: *std.Io.Writer, code: u8, args: anytype) noreturn {
    writer.print("error: " ++ fmt ++ "\n", args) catch |err| std.log.err("failed to write error: {}", .{err});
    writer.flush() catch |err| std.log.err("failed to flush: {}", .{err});
    std.process.exit(code);
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

    sql.appendSlice(allocator, "CREATE TABLE t (") catch fatal("out of memory", writer, exit_parse, .{});
    for (cols, 0..) |col, i| {
        if (i > 0) sql.appendSlice(allocator, ", ") catch fatal("out of memory", writer, exit_parse, .{});
        sql.append(allocator, '"') catch fatal("out of memory", writer, exit_parse, .{});
        for (col) |ch| {
            if (ch == '"') sql.append(allocator, '"') catch fatal("out of memory", writer, exit_parse, .{});
            sql.append(allocator, ch) catch fatal("out of memory", writer, exit_parse, .{});
        }
        sql.appendSlice(allocator, "\" TEXT") catch fatal("out of memory", writer, exit_parse, .{});
    }
    sql.appendSlice(allocator, ")") catch fatal("out of memory", writer, exit_parse, .{});
    sql.append(allocator, 0) catch fatal("out of memory", writer, exit_parse, .{});

    var errmsg: [*c]u8 = null;
    if (c.sqlite3_exec(db, sql.items.ptr, null, null, &errmsg) != c.SQLITE_OK) {
        const msg = if (errmsg != null) std.mem.span(errmsg) else std.mem.span(c.sqlite3_errmsg(db));
        if (errmsg != null) c.sqlite3_free(errmsg);
        fatal("{s}", writer, exit_sql, .{msg});
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

    sql.appendSlice(allocator, "INSERT INTO t VALUES (") catch fatal("out of memory", writer, exit_parse, .{});
    for (0..n) |i| {
        if (i > 0) sql.append(allocator, ',') catch fatal("out of memory", writer, exit_parse, .{});
        sql.append(allocator, '?') catch fatal("out of memory", writer, exit_parse, .{});
    }
    sql.appendSlice(allocator, ")") catch fatal("out of memory", writer, exit_parse, .{});
    sql.append(allocator, 0) catch fatal("out of memory", writer, exit_parse, .{});

    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(db, sql.items.ptr, -1, &stmt, null) != c.SQLITE_OK)
        fatal("{s}", writer, exit_sql, .{std.mem.span(c.sqlite3_errmsg(db))});
    return stmt.?;
}

pub fn beginTransaction(db: *c.sqlite3, writer: *std.Io.Writer) void {
    var errmsg: [*c]u8 = null;
    if (c.sqlite3_exec(db, "BEGIN TRANSACTION", null, null, &errmsg) != c.SQLITE_OK) {
        const msg = if (errmsg != null) std.mem.span(errmsg) else std.mem.span(c.sqlite3_errmsg(db));
        if (errmsg != null) c.sqlite3_free(errmsg);
        fatal("{s}", writer, exit_sql, .{msg});
    }
}

pub fn commitTransaction(db: *c.sqlite3, writer: *std.Io.Writer) void {
    var errmsg: [*c]u8 = null;
    if (c.sqlite3_exec(db, "COMMIT", null, null, &errmsg) != c.SQLITE_OK) {
        const msg = if (errmsg != null) std.mem.span(errmsg) else std.mem.span(c.sqlite3_errmsg(db));
        if (errmsg != null) c.sqlite3_free(errmsg);
        fatal("{s}", writer, exit_sql, .{msg});
    }
}
