const std = @import("std");
const c = @import("c");
const json_mod = @import("../json.zig");
const xml_mod = @import("../xml.zig");
const sqlite_mod = @import("../sqlite.zig");
const loader = @import("../loader.zig");
const format = @import("../format.zig");
const args_mod = @import("../args.zig");
const table = @import("../table.zig");

const ExitCode = args_mod.ExitCode;
const fatal = @import("../sqlite.zig").fatal;
const loadCsvInput = loader.loadCsvInput;

pub fn runStats(
    allocator: std.mem.Allocator,
    io: std.Io,
    args: args_mod.StatsArgs,
    stderr_writer: *std.Io.Writer,
    stdout_writer: *std.Io.Writer,
) void {
    const db = sqlite_mod.openDb(false, stderr_writer);
    defer _ = c.sqlite3_close(db);

    const parsed: args_mod.ParsedArgs = .{
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
    };

    if (args.files.len > 0) {
        for (args.files, 0..) |file_input, i| {
            if (i > 0) stdout_writer.writeByte('\n') catch |err| {
                std.log.err("failed to write output: {}", .{err});
                std.process.exit(@intFromEnum(ExitCode.usage));
            };
            var file_buf: [4096]u8 = undefined;
            const file = std.Io.Dir.openFile(std.Io.Dir.cwd(), io, file_input.path, .{}) catch |err|
                fatal("cannot open file '{s}': {s}", stderr_writer, .csv_error, .{ file_input.path, @errorName(err) });
            defer std.Io.File.close(file, io);
            var file_reader = std.Io.File.reader(file, io, &file_buf);
            loadTable(allocator, io, db, file_input.table_name, file_input.format, &file_reader.interface, parsed, stderr_writer);
            printTableStats(allocator, db, file_input.table_name, stdout_writer, stderr_writer);
        }
    } else {
        var stdin_buf: [4096]u8 = undefined;
        var stdin_reader = std.Io.File.reader(std.Io.File.stdin(), io, &stdin_buf);
        loadTable(allocator, io, db, "t", args.input_format, &stdin_reader.interface, parsed, stderr_writer);
        printTableStats(allocator, db, "t", stdout_writer, stderr_writer);
    }

    stdout_writer.flush() catch |err| std.log.err("failed to flush stdout: {}", .{err});
    stderr_writer.flush() catch |err| std.log.err("failed to flush stderr: {}", .{err});
}

fn loadTable(
    allocator: std.mem.Allocator,
    io: std.Io,
    db: *c.sqlite3,
    table_name: []const u8,
    input_format: format.InputFormat,
    reader: *std.Io.Reader,
    parsed: args_mod.ParsedArgs,
    stderr_writer: *std.Io.Writer,
) void {
    const rows = switch (input_format) {
        .csv => loadCsvInput(allocator, io, db, table_name, reader, parsed, stderr_writer),
        .tsv => blk: {
            var tsv_parsed = parsed;
            tsv_parsed.delimiter = "\t";
            break :blk loadCsvInput(allocator, io, db, table_name, reader, tsv_parsed, stderr_writer);
        },
        .json => json_mod.loadJsonArray(allocator, reader, db, table_name, parsed.max_rows, parsed.json_path, stderr_writer),
        .ndjson => json_mod.loadNdjsonInput(allocator, reader, db, table_name, parsed.max_rows, stderr_writer),
        .xml => xml_mod.loadXmlInput(allocator, reader, db, table_name, parsed.xml_root_input, parsed.xml_row_input, parsed.max_rows, stderr_writer),
    };
    if (rows == 0) fatal("empty input", stderr_writer, .csv_error, .{});
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
