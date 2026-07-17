const std = @import("std");
const c = @import("c");
const args_mod = @import("../args.zig");
const sqlite_mod = @import("../sqlite.zig");
const main_mod = @import("../main.zig");
const loader = @import("../loader.zig");
const builtin = @import("builtin");

// ponytail: linenoise on Unix, plain stdin on Windows — same API, different backend
const linenoise = if (builtin.os.tag != .windows) @cImport({
    @cInclude("linenoise.h");
}) else struct {};

const ParsedArgs = args_mod.ParsedArgs;
const fatal = sqlite_mod.fatal;
const printSqlError = sqlite_mod.printSqlError;
const fmtThousands = loader.fmtThousands;

/// Read a line with prompt. Returns heap-allocated null-terminated string, or null on EOF.
/// Caller must call freeLine() to free.
/// On Windows, stdin_reader must be a persistent reader (created once before the loop).
fn readLine(allocator: std.mem.Allocator, io: std.Io, stdin_reader: anytype, prompt: []const u8) ?[:0]u8 {
    if (builtin.os.tag == .windows) {
        // Write prompt to stderr — keeps stdout clean for piping (B1)
        var err_buf: [256]u8 = undefined;
        var stderr_w = std.Io.File.writer(std.Io.File.stderr(), io, &err_buf);
        stderr_w.writeAll(prompt) catch return null;
        stderr_w.flush() catch return null;

        // ponytail: 8KB line limit; bump if users report truncation (B3)
        var buf: [8192]u8 = undefined;
        const raw = stdin_reader.readUntilDelimiterOrEof(&buf, '\n') catch return null orelse return null;

        // Strip trailing \r (Windows CRLF)
        const trimmed = if (raw.len > 0 and raw[raw.len - 1] == '\r') raw[0 .. raw.len - 1] else raw;

        const copy = allocator.allocSentinel(u8, trimmed.len, 0) catch return null;
        @memcpy(copy[0..trimmed.len], trimmed);
        return copy;
    } else {
        const ptr = linenoise.linenoise(@as([*c]const u8, @ptrCast(prompt)));
        if (ptr == null) return null;
        return std.mem.span(ptr);
    }
}

fn freeLine(allocator: std.mem.Allocator, line: ?[:0]u8) void {
    if (line == null) return;
    if (builtin.os.tag == .windows) {
        allocator.free(line.?);
    } else {
        linenoise.linenoiseFree(@ptrCast(line.?));
    }
}

fn historyAdd(line: ?[:0]u8) void {
    if (builtin.os.tag == .windows) return;
    if (line) |l| {
        _ = linenoise.linenoiseHistoryAdd(@as([*c]const u8, @ptrCast(l)));
    }
}

fn historyLoad(path: ?[:0]u8) void {
    if (builtin.os.tag == .windows) return;
    // ponytail: SetMaxLen before Load so existing huge files get trimmed (S2)
    _ = linenoise.linenoiseHistorySetMaxLen(1000);
    if (path) |p| {
        _ = linenoise.linenoiseHistoryLoad(@as([*c]const u8, @ptrCast(p)));
    }
}

fn historySave(path: ?[:0]u8) void {
    if (builtin.os.tag == .windows) return;
    if (path) |p| {
        _ = linenoise.linenoiseHistorySave(@as([*c]const u8, @ptrCast(p)));
    }
}

fn execReplQuery(
    allocator: std.mem.Allocator,
    db: *c.sqlite3,
    query: []const u8,
    stdout_writer: *std.Io.Writer,
    stderr_writer: *std.Io.Writer,
    parsed: ParsedArgs,
    use_table: bool,
    main_table: []const u8,
) void {
    main_mod.execQuery(
        allocator, db, query, stdout_writer,
        parsed.header, parsed.output_format,
        parsed.xml_root, parsed.xml_row,
        parsed.sql_table, parsed.html_class,
        parsed.null_value, use_table,
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
}

fn execDotQuery(
    allocator: std.mem.Allocator,
    db: *c.sqlite3,
    query: []const u8,
    stdout_writer: *std.Io.Writer,
    stderr_writer: *std.Io.Writer,
    parsed: ParsedArgs,
    use_table: bool,
    main_table: []const u8,
) bool {
    execReplQuery(allocator, db, query, stdout_writer, stderr_writer, parsed, use_table, main_table);
    stdout_writer.flush() catch |err| std.log.err("failed to flush stdout: {}", .{err});
    return true;
}

fn handleDotCommand(
    allocator: std.mem.Allocator,
    io: std.Io,
    command: []const u8,
    db: *c.sqlite3,
    stdout_writer: *std.Io.Writer,
    stderr_writer: *std.Io.Writer,
    parsed: ParsedArgs,
    use_table: bool,
    main_table: []const u8,
    _: ?[:0]u8,
) bool {
    const trimmed = std.mem.trim(u8, command, " \t\r\n");
    if (trimmed.len == 0 or trimmed[0] != '.') return false;

    // Parse: split on first space to get command and optional argument
    const first_space = std.mem.indexOfAny(u8, trimmed, " \t");
    const cmd = if (first_space) |pos| trimmed[1..pos] else trimmed[1..];
    const arg = if (first_space) |pos| std.mem.trim(u8, trimmed[pos+1..], " \t\r\n") else null;

    if (std.mem.eql(u8, cmd, "help")) {
        stderr_writer.writeAll(
            \\.help                Show this help
            \\.tables              List all table names
            \\.schema [table]      Show CREATE TABLE DDL (all tables if no name given)
            \\.read <file>         Load and execute queries from file
            \\.exit, .quit, .q     Exit the REPL
        ) catch {};
        stderr_writer.flush() catch |err| std.log.err("failed to flush stderr: {}", .{err});
        return true;
    }
    if (std.mem.eql(u8, cmd, "tables")) {
        return execDotQuery(allocator, db, "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name", stdout_writer, stderr_writer, parsed, use_table, main_table);
    }
    if (std.mem.eql(u8, cmd, "schema")) {
        var query: [256]u8 = undefined;
        const query_str = if (arg) |table_name|
            std.fmt.bufPrint(&query, "SELECT sql FROM sqlite_master WHERE type='table' AND name='{s}'", .{table_name}) catch {
                stderr_writer.print("error: table name too long\n", .{}) catch {};
                return true;
            }
        else
            "SELECT sql FROM sqlite_master WHERE type='table'";
        return execDotQuery(allocator, db, query_str, stdout_writer, stderr_writer, parsed, use_table, main_table);
    }
    if (std.mem.eql(u8, cmd, "read")) {
        if (arg == null or arg.?.len == 0) {
            stderr_writer.print("usage: .read <file>\n", .{}) catch {};
            return true;
        }
        const file_contents = std.Io.Dir.cwd().readFileAlloc(io, arg.?, allocator, .limited(10 * 1024 * 1024)) catch |err| {
            stderr_writer.print("error reading file '{s}': {s}\n", .{ arg.?, @errorName(err) }) catch {};
            return true;
        };
        defer allocator.free(file_contents);
        var queries = std.mem.splitScalar(u8, file_contents, ';');
        while (queries.next()) |query| {
            const q = std.mem.trim(u8, query, " \t\r\n");
            if (q.len == 0) continue;
            execReplQuery(allocator, db, q, stdout_writer, stderr_writer, parsed, use_table, main_table);
        }
        stdout_writer.flush() catch |err| std.log.err("failed to flush stdout: {}", .{err});
        return true;
    }
    stderr_writer.print("unknown command: {s}\n", .{command}) catch {};
    return true;
}

/// runRepl(allocator, io, parsed, stderr_writer, stdout_writer, use_table) → void
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

    if (!parsed.silent) {
        var count_buf: [32]u8 = undefined;
        const count_str = fmtThousands(&count_buf, total_rows);
        stderr_writer.print("Loaded {s} rows\n", .{count_str}) catch |err| {
            std.log.err("failed to write row count: {}", .{err});
        };
        stderr_writer.flush() catch |err| std.log.err("failed to flush stderr: {}", .{err});
    }

    // History path — only used on Unix
    var history_path: ?[:0]u8 = null;
    if (builtin.os.tag != .windows) {
        const home_env = std.c.getenv("HOME");
        const home: []const u8 = if (home_env) |h| std.mem.span(h) else ".";
        if (std.fmt.allocPrintSentinel(allocator, "{s}/.sqlpipe_history", .{home}, 0)) |p| {
            history_path = p;
        } else |_| {}
    }
    defer if (history_path) |p| allocator.free(p);

    historyLoad(history_path);

    const main_table = main_mod.mainTableName(parsed);

    // ponytail: persistent stdin reader for Windows — avoids buffer loss across iterations (B2)
    var stdin_buf: [8192]u8 = undefined;
    var stdin_r = std.Io.File.reader(std.Io.File.stdin(), io, &stdin_buf);

    stderr_writer.writeAll("Entering interactive mode. Type .exit, .quit, Ctrl-D, or Ctrl-C to quit.\n") catch {};
    stderr_writer.flush() catch |err| std.log.err("failed to flush stderr: {}", .{err});

    var ml_buf: std.ArrayList(u8) = .empty;
    defer ml_buf.deinit(allocator);

    while (true) {
        const prompt = if (ml_buf.items.len > 0) "...> " else "sql> ";
        const line = readLine(allocator, io, &stdin_r, prompt);
        if (line == null) break;
        defer freeLine(allocator, line);
        const trimmed = std.mem.trim(u8, line.?, " \t\r\n");

        // Multi-line: empty line executes accumulated buffer
        if (ml_buf.items.len > 0 and trimmed.len == 0) {
            const query = ml_buf.items;
            execReplQuery(allocator, db, query, stdout_writer, stderr_writer, parsed, use_table, main_table);
            ml_buf.clearRetainingCapacity();
            stdout_writer.flush() catch |err| std.log.err("failed to flush stdout: {}", .{err});
            continue;
        }

        if (trimmed.len == 0) continue;

        // Exit commands (always work, even in multi-line)
        if (std.mem.eql(u8, trimmed, ".exit") or std.mem.eql(u8, trimmed, ".quit") or std.mem.eql(u8, trimmed, ".q")) break;

        // Dot commands only in single-line mode (NOT in multi-line)
        if (ml_buf.items.len == 0 and trimmed[0] == '.') {
            if (handleDotCommand(allocator, io, trimmed, db, stdout_writer, stderr_writer, parsed, use_table, main_table, history_path)) continue;
        }

        // Append to multi-line buffer
        const ends_with_semicolon = trimmed.len > 0 and trimmed[trimmed.len - 1] == ';';
        if (ml_buf.items.len > 0) {
            ml_buf.append(allocator, ' ') catch { break; };
        }
        ml_buf.appendSlice(allocator, trimmed) catch { break; };

        if (!ends_with_semicolon) continue;

        // Strip trailing ; and execute
        const query_len = if (ml_buf.items.len > 0 and ml_buf.items[ml_buf.items.len - 1] == ';')
            ml_buf.items.len - 1 else ml_buf.items.len;
        const query = ml_buf.items[0..query_len];

        if (query.len == 0) {
            ml_buf.clearRetainingCapacity();
            continue;
        }

        historyAdd(null); // Only persist manually
        historySave(history_path);

        execReplQuery(allocator, db, query, stdout_writer, stderr_writer, parsed, use_table, main_table);
        ml_buf.clearRetainingCapacity();
        stdout_writer.flush() catch |err| std.log.err("failed to flush stdout: {}", .{err});
    }
}
