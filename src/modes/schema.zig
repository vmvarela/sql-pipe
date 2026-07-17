const std = @import("std");
const c = @import("c");
const build_options = @import("build_options");
const parquet_mod = @import("../parquet.zig");
const sqlite_mod = @import("../sqlite.zig");
const args_mod = @import("../args.zig");
const main_mod = @import("../main.zig");

const ExitCode = args_mod.ExitCode;
const fatal = sqlite_mod.fatal;

pub fn runSchema(
    allocator: std.mem.Allocator,
    io: std.Io,
    args: args_mod.SchemaArgs,
    stderr_writer: *std.Io.Writer,
    stdout_writer: *std.Io.Writer,
) void {
    const db = sqlite_mod.openDb(false, null, stderr_writer);
    defer _ = c.sqlite3_close(db);

    var parsed = args_mod.ParsedArgs{
        .query = "",
        .files = args.files,
        .type_inference = args.type_inference,
        .delimiter = args.delimiter,
        .header = false,
        .input_format = args.input_format,
        .output_format = .csv,
        .max_rows = null,
        .verbose = false,
        .silent = true,
        .output = null,
        .xml_root = "results",
        .xml_row = "row",
        .xml_root_input = null,
        .xml_row_input = null,
        .json_path = null,
        .disk = false,
        .url = args.url,
    };
    parsed.has_stdin = if (parsed.url != null) false else !(std.Io.File.isTty(std.Io.File.stdin(), io) catch false);

    const total_rows = main_mod.loadPipelineInputs(allocator, io, db, parsed, stderr_writer);
    if (total_rows == 0 and (parsed.has_stdin or parsed.files.len > 0 or parsed.url != null))
        fatal("empty input", stderr_writer, .csv_error, .{});

    // Print DDL for each table in creation order
    var seen_first = false;
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
        if (seen_first) {
            stdout_writer.writeByte('\n') catch |err| {
                std.log.err("failed to write output: {}", .{err});
                std.process.exit(@intFromEnum(ExitCode.usage));
            };
        }
        seen_first = true;
        printTableSchema(allocator, db, name, stdout_writer, stderr_writer);
    }

    stdout_writer.flush() catch |err| std.log.err("failed to flush stdout: {}", .{err});
    stderr_writer.flush() catch |err| std.log.err("failed to flush stderr: {}", .{err});
}

fn printTableSchema(
    allocator: std.mem.Allocator,
    db: *c.sqlite3,
    table_name: []const u8,
    stdout_writer: *std.Io.Writer,
    stderr_writer: *std.Io.Writer,
) void {
    var sql: std.ArrayList(u8) = .empty;
    defer sql.deinit(allocator);
    sql.appendSlice(allocator, "SELECT sql FROM sqlite_master WHERE type='table' AND name=") catch
        fatal("out of memory", stderr_writer, .csv_error, .{});
    sqlite_mod.appendQuotedId(allocator, stderr_writer, &sql, table_name);
    sql.append(allocator, 0) catch
        fatal("out of memory", stderr_writer, .csv_error, .{});

    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(db, sql.items.ptr, -1, &stmt, null) != c.SQLITE_OK)
        fatal("failed to prepare schema query", stderr_writer, .sql_error, .{});
    defer _ = c.sqlite3_finalize(stmt);

    if (c.sqlite3_step(stmt) != c.SQLITE_ROW)
        fatal("schema not found in sqlite_master", stderr_writer, .sql_error, .{});

    const ddl = sqlite_mod.columnText(stmt.?, 0) orelse
        fatal("sqlite_master.sql is NULL", stderr_writer, .sql_error, .{});

    stdout_writer.writeAll(ddl) catch |err| {
        std.log.err("failed to write schema: {}", .{err});
        std.process.exit(@intFromEnum(ExitCode.usage));
    };
    stdout_writer.writeAll(";\n") catch |err| {
        std.log.err("failed to write schema: {}", .{err});
        std.process.exit(@intFromEnum(ExitCode.usage));
    };
}
