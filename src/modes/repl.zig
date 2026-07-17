const std = @import("std");
const c = @import("c");
const args_mod = @import("../args.zig");
const sqlite_mod = @import("../sqlite.zig");
const main_mod = @import("../main.zig");
const loader = @import("../loader.zig");

const linenoise = @cImport({
    @cInclude("linenoise.h");
});

const ParsedArgs = args_mod.ParsedArgs;
const fatal = sqlite_mod.fatal;
const printSqlError = sqlite_mod.printSqlError;
const fmtThousands = loader.fmtThousands;

/// runRepl(allocator, io, parsed, stderr_writer, stdout_writer, use_table) → void
/// Pre:  parsed contains input sources (files/stdin). No query required.
/// Post: inputs loaded into SQLite, enters interactive REPL loop.
///       On .exit/.quit/.q/Ctrl-D/Ctrl-C: exits cleanly with code 0.
///       On fatal input error: exits via fatal().
///       SQL errors are printed to stderr, REPL continues.
///       Multi-statement lines: only first statement executes (v1).
pub fn runRepl(
    allocator: std.mem.Allocator,
    io: std.Io,
    parsed: ParsedArgs,
    stderr_writer: *std.Io.Writer,
    stdout_writer: *std.Io.Writer,
    use_table: bool,
) void {
    const db = sqlite_mod.openDb(parsed.disk, parsed.save_path, stderr_writer);
    defer _ = c.sqlite3_close(db);

    const total_rows = main_mod.loadPipelineInputs(allocator, io, db, parsed, stderr_writer);

    // Print loaded summary
    if (!parsed.silent) {
        var count_buf: [32]u8 = undefined;
        const count_str = fmtThousands(&count_buf, total_rows);
        stderr_writer.print("Loaded {s} rows\n", .{count_str}) catch |err| {
            std.log.err("failed to write row count: {}", .{err});
        };
        stderr_writer.flush() catch |err| std.log.err("failed to flush stderr: {}", .{err});
    }

    // ponytail: history to $HOME/.sqlpipe_history, no cross-platform home-dir library needed
    // ponytail: SetMaxLen before Load so existing huge files get trimmed (S2)
    const home_env = std.c.getenv("HOME");
    const home: []const u8 = if (home_env) |h| std.mem.span(h) else ".";
    var history_path: ?[:0]u8 = null;
    if (std.fmt.allocPrintSentinel(allocator, "{s}/.sqlpipe_history", .{home}, 0)) |p| {
        history_path = p;
    } else |err| {
        stderr_writer.print("warning: failed to resolve history path: {s}\n", .{@errorName(err)}) catch {};
    }
    defer if (history_path) |p| allocator.free(p);

    _ = linenoise.linenoiseHistorySetMaxLen(1000);
    if (history_path) |p| {
        _ = linenoise.linenoiseHistoryLoad(p);
    }

    const main_table = main_mod.mainTableName(parsed);

    stderr_writer.writeAll("Entering interactive mode. Type .exit, .quit, Ctrl-D, or Ctrl-C to quit.\n") catch {};
    stderr_writer.flush() catch |err| std.log.err("failed to flush stderr: {}", .{err});

    while (true) {
        const line: ?[*:0]u8 = linenoise.linenoise("sql> ");
        if (line == null) break; // EOF / Ctrl-D / Ctrl-C

        defer linenoise.linenoiseFree(@ptrCast(line.?));

        const trimmed = std.mem.trim(u8, std.mem.span(line.?), " \t\r\n");
        if (trimmed.len == 0) continue;

        // ponytail: .exit, .quit, .q — all exit REPL (S9)
        if (std.mem.eql(u8, trimmed, ".exit") or
            std.mem.eql(u8, trimmed, ".quit") or
            std.mem.eql(u8, trimmed, ".q"))
        {
            break;
        }

        _ = linenoise.linenoiseHistoryAdd(line.?);
        if (history_path) |p| {
            _ = linenoise.linenoiseHistorySave(p);
        }

        // Strip trailing semicolon (SQLite accepts it, but cleaner without)
        const query = if (trimmed.len > 0 and trimmed[trimmed.len - 1] == ';')
            std.mem.trim(u8, trimmed[0 .. trimmed.len - 1], " \t\r\n")
        else
            trimmed;

        // ponytail: guard against empty query after strip (S3: input ";" → "")
        if (query.len == 0) continue;

        main_mod.execQuery(
            allocator,
            db,
            query,
            stdout_writer,
            parsed.header,
            parsed.output_format,
            parsed.xml_root,
            parsed.xml_row,
            parsed.sql_table,
            parsed.html_class,
            parsed.null_value,
            use_table,
        ) catch |err| switch (err) {
            error.PrepareQueryFailed => {
                stdout_writer.flush() catch |err_flush| std.log.err("failed to flush stdout: {}", .{err_flush});
                printSqlError(allocator, db, main_table, std.mem.span(c.sqlite3_errmsg(db)), stderr_writer);
            },
            else => {
                stdout_writer.flush() catch |err_flush| std.log.err("failed to flush stdout: {}", .{err_flush});
                stderr_writer.print("error: {s}\n", .{@errorName(err)}) catch {};
                stderr_writer.flush() catch |err_flush| std.log.err("failed to flush stderr: {}", .{err_flush});
            },
        };

        stdout_writer.flush() catch |err| std.log.err("failed to flush stdout: {}", .{err});
    }
}
