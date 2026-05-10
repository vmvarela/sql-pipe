const std = @import("std");
const c = @import("c");
const json = @import("json.zig");
const xml = @import("xml.zig");
const format = @import("format.zig");
const build_options = @import("build_options");
const args_mod = @import("args.zig");
const sqlite_mod = @import("sqlite.zig");
const loader = @import("loader.zig");

const columns_mode = @import("modes/columns.zig");
const validate_mode = @import("modes/validate.zig");
const sample_mode = @import("modes/sample.zig");

const VERSION: []const u8 = build_options.version;

const SqlPipeError = args_mod.SqlPipeError;
const ParsedArgs = args_mod.ParsedArgs;
const ExitCode = args_mod.ExitCode;
const parseArgs = args_mod.parseArgs;
const printUsage = args_mod.printUsage;

const loadCsvInput = loader.loadCsvInput;
const fmtThousands = loader.fmtThousands;
const progress_interval = loader.progress_interval;
const fatal = sqlite_mod.fatal;

/// Supported input formats (canonical definition lives in format.zig).
const InputFormat = format.InputFormat;

/// Supported output formats (canonical definition lives in format.zig).
const OutputFormat = format.OutputFormat;

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

    const db = sqlite_mod.openDb(parsed.disk, stderr_writer);
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
            error.IncompatibleFlags => fatal("--header cannot be combined with non-CSV/TSV output format", stderr_writer, .usage, .{}),
            error.SilentVerboseConflict => fatal("--silent cannot be combined with --verbose", stderr_writer, .usage, .{}),
            error.InvalidMaxRows => fatal("--max-rows must be a positive integer", stderr_writer, .usage, .{}),
            error.InvalidInputFormat => fatal("unknown input format; supported: csv, tsv, json, ndjson, xml", stderr_writer, .usage, .{}),
            error.InvalidOutputFormat => fatal("unknown output format; supported: csv, tsv, json, ndjson, xml", stderr_writer, .usage, .{}),
            error.ColumnsWithQuery => fatal("--columns cannot be combined with a query argument", stderr_writer, .usage, .{}),
            error.ValidateWithQuery => fatal("--validate cannot be combined with a query argument", stderr_writer, .usage, .{}),
            error.InvalidOutputPath => fatal("--output requires a non-empty file path", stderr_writer, .usage, .{}),
            error.OutputWithColumns => fatal("--output cannot be combined with --columns", stderr_writer, .usage, .{}),
            error.OutputWithValidate => fatal("--output cannot be combined with --validate", stderr_writer, .usage, .{}),
            error.ValidateWithColumns => fatal("--validate cannot be combined with --columns", stderr_writer, .usage, .{}),
            error.SampleWithQuery => fatal("--sample cannot be combined with a query argument", stderr_writer, .usage, .{}),
            error.SampleWithJson => fatal("--sample cannot be combined with --json or a JSON output format", stderr_writer, .usage, .{}),
            error.SampleWithColumns => fatal("--sample cannot be combined with --columns", stderr_writer, .usage, .{}),
            error.SampleWithValidate => fatal("--sample cannot be combined with --validate", stderr_writer, .usage, .{}),
            error.SampleWithOutput => fatal("--sample cannot be combined with --output", stderr_writer, .usage, .{}),
            error.InvalidSampleCount => fatal("--sample requires a positive integer value", stderr_writer, .usage, .{}),
            error.MissingXmlFlagValue => fatal("--xml-root and --xml-row require a value", stderr_writer, .usage, .{}),
            error.InvalidXmlName => fatal("--xml-root and --xml-row must be valid XML element names (letter/underscore first, then letters/digits/-/._/:)", stderr_writer, .usage, .{}),
            else => {},
        }
        printUsage(stderr_writer) catch |werr| std.log.err("failed to write usage: {}", .{werr});
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
            columns_mode.runColumns(allocator, io.io(), col_args, stderr_writer, stdout_writer);
            stdout_file_writer.flush() catch |err| {
                std.log.err("failed to flush stdout: {}", .{err});
            };
            stderr_file_writer.flush() catch |err| {
                std.log.err("failed to flush stderr: {}", .{err});
            };
        },
        .validate => |val_args| {
            validate_mode.runValidate(allocator, io.io(), val_args, stderr_writer, stdout_writer);
            stdout_file_writer.flush() catch |err| {
                std.log.err("failed to flush stdout: {}", .{err});
            };
            stderr_file_writer.flush() catch |err| {
                std.log.err("failed to flush stderr: {}", .{err});
            };
        },
        .sample => |sample_args| {
            sample_mode.runSample(allocator, io.io(), sample_args, stderr_writer, stdout_writer);
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
