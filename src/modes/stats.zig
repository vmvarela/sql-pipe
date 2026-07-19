const std = @import("std");
const c = @import("c");
const build_options = @import("build_options");
const parquet_mod = @import("../parquet.zig");
const sqlite_mod = @import("../sqlite.zig");
const args_mod = @import("../args.zig");
const table = @import("../table.zig");
const main_mod = @import("../main.zig");

const ExitCode = args_mod.ExitCode;
const fatal = sqlite_mod.fatal;

pub fn runStats(
    allocator: std.mem.Allocator,
    io: std.Io,
    parsed_in: args_mod.ParsedArgs,
    stderr_writer: *std.Io.Writer,
    stdout_writer: *std.Io.Writer,
) void {
    var parsed = parsed_in;
    parsed.max_rows = null;
    const db = sqlite_mod.openDb(false, null, stderr_writer);
    defer _ = c.sqlite3_close(db);

    parsed.has_stdin = if (parsed.urls.len > 0) false else !(std.Io.File.isTty(std.Io.File.stdin(), io) catch false);

    const total_rows = main_mod.loadPipelineInputs(allocator, io, db, parsed, stderr_writer);
    if (total_rows == 0 and (parsed.has_stdin or parsed.files.len > 0 or parsed.urls.len > 0))
        fatal("empty input", stderr_writer, .csv_error, .{});

    // Print stats for each table in creation order
    var sql = std.ArrayList(u8).empty;
    defer sql.deinit(allocator);

    sql.appendSlice(allocator, "SELECT name FROM sqlite_master WHERE type='table' ORDER BY rowid") catch
        fatal("out of memory", stderr_writer, .csv_error, .{});
    sql.append(allocator, 0) catch fatal("out of memory", stderr_writer, .csv_error, .{});

    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(db, sql.items.ptr, -1, &stmt, null) != c.SQLITE_OK)
        fatal("failed to list tables", stderr_writer, .csv_error, .{});
    defer _ = c.sqlite3_finalize(stmt);

    while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
        const name = sqlite_mod.columnText(stmt.?, 0) orelse continue;
        printTableStats(allocator, db, name, stdout_writer, stderr_writer);
        stdout_writer.writeByte('\n') catch |err| {
            std.log.err("failed to write output: {}", .{err});
            std.process.exit(@intFromEnum(ExitCode.usage));
        };
    }

    stdout_writer.flush() catch |err| std.log.err("failed to flush stdout: {}", .{err});
    stderr_writer.flush() catch |err| std.log.err("failed to flush stderr: {}", .{err});
}

fn printTableStats(
    allocator: std.mem.Allocator,
    db: *c.sqlite3,
    table_name: []const u8,
    stdout_writer: *std.Io.Writer,
    stderr_writer: *std.Io.Writer,
) void {
    const info = sqlite_mod.getTableColumnsWithTypes(allocator, db, table_name, stderr_writer);
    defer {
        for (info.names) |n| allocator.free(n);
        allocator.free(info.names);
        for (info.types) |t| allocator.free(t);
        allocator.free(info.types);
    }

    if (info.names.len == 0) return;

    var sql: std.ArrayList(u8) = .empty;
    defer sql.deinit(allocator);
    sql.appendSlice(allocator, "SELECT \"column\", \"type\", \"non-null\", \"min\", \"max\", \"mean\" FROM (") catch
        fatal("out of memory", stderr_writer, .csv_error, .{});

    for (info.names, info.types, 0..) |col_name, col_type, i| {
        sql.appendSlice(allocator, if (i > 0) " UNION ALL SELECT " else "SELECT ") catch
            fatal("out of memory", stderr_writer, .csv_error, .{});

        sqlite_mod.appendStringLiteral(allocator, stderr_writer, &sql, col_name);
        sql.appendSlice(allocator, " AS \"column\", '") catch fatal("out of memory", stderr_writer, .csv_error, .{});
        sql.appendSlice(allocator, col_type) catch fatal("out of memory", stderr_writer, .csv_error, .{});
        sql.appendSlice(allocator, "' AS \"type\", COUNT(") catch fatal("out of memory", stderr_writer, .csv_error, .{});
        sqlite_mod.appendQuotedId(allocator, stderr_writer, &sql, col_name);
        sql.appendSlice(allocator, ") AS \"non-null\", MIN(") catch fatal("out of memory", stderr_writer, .csv_error, .{});
        sqlite_mod.appendQuotedId(allocator, stderr_writer, &sql, col_name);
        sql.appendSlice(allocator, ") AS \"min\", MAX(") catch fatal("out of memory", stderr_writer, .csv_error, .{});
        sqlite_mod.appendQuotedId(allocator, stderr_writer, &sql, col_name);
        sql.appendSlice(allocator, ") AS \"max\", CASE WHEN '") catch fatal("out of memory", stderr_writer, .csv_error, .{});
        sql.appendSlice(allocator, col_type) catch fatal("out of memory", stderr_writer, .csv_error, .{});
        sql.appendSlice(allocator, "' IN ('INTEGER','REAL') THEN CAST(AVG(") catch fatal("out of memory", stderr_writer, .csv_error, .{});
        sqlite_mod.appendQuotedId(allocator, stderr_writer, &sql, col_name);
        sql.appendSlice(allocator, ") AS TEXT) ELSE '' END AS \"mean\", ") catch fatal("out of memory", stderr_writer, .csv_error, .{});
        var cid_buf: [16]u8 = undefined;
        const cid_str = std.fmt.bufPrint(&cid_buf, "{d}", .{i}) catch fatal("out of memory", stderr_writer, .csv_error, .{});
        sql.appendSlice(allocator, cid_str) catch fatal("out of memory", stderr_writer, .csv_error, .{});
        sql.appendSlice(allocator, " AS \"cid\" FROM ") catch fatal("out of memory", stderr_writer, .csv_error, .{});
        sqlite_mod.appendQuotedId(allocator, stderr_writer, &sql, table_name);
    }

    sql.appendSlice(allocator, ") ORDER BY \"cid\"") catch fatal("out of memory", stderr_writer, .csv_error, .{});
    sql.append(allocator, 0) catch fatal("out of memory", stderr_writer, .csv_error, .{});

    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(db, sql.items.ptr, -1, &stmt, null) != c.SQLITE_OK)
        fatal("failed to prepare stats query", stderr_writer, .sql_error, .{});

    defer _ = c.sqlite3_finalize(stmt);
    const col_count = c.sqlite3_column_count(stmt);
    if (col_count == 0) return;

    table.writeTable(allocator, stdout_writer, stmt.?, col_count, null) catch |err| {
        std.log.err("failed to write stats table: {}", .{err});
        std.process.exit(@intFromEnum(ExitCode.usage));
    };
}
