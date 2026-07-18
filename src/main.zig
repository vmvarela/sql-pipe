const std = @import("std");
const c = @import("c");
const json = @import("json.zig");
const xml = @import("xml.zig");
const format = @import("format.zig");
const table = @import("table.zig");
const markdown = @import("markdown.zig");
const build_options = @import("build_options");
const args_mod = @import("args.zig");
const sqlite_mod = @import("sqlite.zig");
const loader = @import("loader.zig");
const yaml_mod = @import("yaml.zig");
const http_mod = @import("http.zig");
const parquet_mod = @import("parquet.zig");

const inspect_mode = @import("modes/inspect.zig");
const repl_mode = @import("modes/repl.zig");
const completions_mod = @import("completions.zig");

const VERSION: []const u8 = build_options.version;

const SqlPipeError = args_mod.SqlPipeError;
const ParsedArgs = args_mod.ParsedArgs;
const ExitCode = args_mod.ExitCode;
const TableMode = args_mod.TableMode;
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

/// execQuery(allocator, db, query, writer, header, output_format, ...) → !void
/// Pre:  db is open with tables populated
///       query is a valid SQL string (not null-terminated)
///       allocator is valid
///       when output_format = .json or .ndjson, header must not be set (caller's responsibility)
///       when use_table = true, output_format must be .csv or .tsv (caller's responsibility)
/// Post: results are written to writer in the requested output format (or as a pretty table)
///       error.PrepareQueryFailed when sqlite3_prepare_v2 returns non-SQLITE_OK
///       propagates any writer I/O error
pub fn execQuery(
    allocator: std.mem.Allocator,
    db: *c.sqlite3,
    query: []const u8,
    writer: *std.Io.Writer,
    header: bool,
    output_format: OutputFormat,
    xml_root: []const u8,
    xml_row: []const u8,
    sql_table: []const u8,
    html_class: []const u8,
    null_value: ?[]const u8,
    use_table: bool,
) (SqlPipeError || std.mem.Allocator.Error || error{ WriteFailed, StepFailed })!void {
    const query_z = try allocator.dupeZ(u8, query);
    defer allocator.free(query_z);

    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(db, query_z.ptr, -1, &stmt, null) != c.SQLITE_OK)
        return error.PrepareQueryFailed;
    defer _ = c.sqlite3_finalize(stmt);

    const col_count = c.sqlite3_column_count(stmt);

    // Table mode: buffer all rows and print a formatted table
    if (use_table) {
        try table.writeTable(allocator, writer, stmt.?, col_count, null_value);
        return;
    }

    // Markdown output: two-pass writer (not streaming)
    if (output_format == .markdown) {
        try markdown.writeMarkdown(allocator, writer, stmt.?, col_count, null_value);
        return;
    }

    var out_writer = format.OutputWriter.init(output_format, .{
        .header = header,
        .xml_root = xml_root,
        .xml_row = xml_row,
        .sql_table = sql_table,
        .html_class = html_class,
        .null_value = null_value,
    });
    defer out_writer.deinit(allocator);

    try out_writer.begin(allocator, stmt.?, col_count, writer);
    while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
        try out_writer.writeRow(stmt.?, writer);
    }
    try out_writer.end(writer);
}

/// loadInput(allocator, io, db, table_name, input_format, reader, parsed, stderr_writer) → usize
/// Pre:  reader points to open input (file or stdin)
/// Post: dispatches to the correct loader based on format; returns number of rows loaded
fn loadInput(
    allocator: std.mem.Allocator,
    io: std.Io,
    db: *c.sqlite3,
    table_name: []const u8,
    input_format: InputFormat,
    reader: *std.Io.Reader,
    parsed: ParsedArgs,
    stderr_writer: *std.Io.Writer,
) usize {
    return switch (input_format) {
        .csv => loadCsvInput(allocator, io, db, table_name, reader, parsed, stderr_writer),
        .tsv => blk: {
            var tsv_parsed = parsed;
            tsv_parsed.delimiter = "\t";
            break :blk loadCsvInput(allocator, io, db, table_name, reader, tsv_parsed, stderr_writer);
        },
        .json => json.loadJsonArray(allocator, reader, db, table_name, parsed.max_rows, parsed.json_path, stderr_writer),
        .ndjson => json.loadNdjsonInput(allocator, reader, db, table_name, parsed.max_rows, stderr_writer),
        .xml => xml.loadXmlInput(allocator, reader, db, table_name, parsed.xml_root_input, parsed.xml_row_input, parsed.max_rows, stderr_writer),
        .yaml => yaml_mod.loadYamlInput(allocator, reader, db, table_name, parsed.max_rows, stderr_writer),
        .parquet => parquet_mod.loadParquetInput(allocator, io, db, table_name, reader, parsed.max_rows, stderr_writer),
    };
}

/// printQueryPlan(allocator, db, query, main_table, stderr_writer) → void
/// Pre:  db is open with tables populated; query is a valid SQL string
/// Post: EXPLAIN QUERY PLAN has been written to stderr, one line per plan row,
///       prefixed with "QUERY PLAN: ". Stderr is flushed after writing.
///       On SQL error, exits with sql_error via fatalSqlWithContext.
fn printQueryPlan(
    allocator: std.mem.Allocator,
    db: *c.sqlite3,
    query: []const u8,
    main_table: []const u8,
    stderr_writer: *std.Io.Writer,
) void {
    // Build null-terminated "EXPLAIN QUERY PLAN <query>" using ArrayList (no allocPrintZ in 0.16).
    var eqp_buf: std.ArrayList(u8) = .empty;
    defer eqp_buf.deinit(allocator);
    eqp_buf.appendSlice(allocator, "EXPLAIN QUERY PLAN ") catch
        sqlite_mod.fatal("out of memory", stderr_writer, .csv_error, .{});
    eqp_buf.appendSlice(allocator, query) catch
        sqlite_mod.fatal("out of memory", stderr_writer, .csv_error, .{});
    eqp_buf.append(allocator, 0) catch
        sqlite_mod.fatal("out of memory", stderr_writer, .csv_error, .{});
    const eqp_query: [*:0]const u8 = @ptrCast(eqp_buf.items.ptr);

    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(db, eqp_query, -1, &stmt, null) != c.SQLITE_OK) {
        sqlite_mod.fatalSqlWithContext(allocator, db, main_table, std.mem.span(c.sqlite3_errmsg(db)), stderr_writer);
    }
    defer _ = c.sqlite3_finalize(stmt);

    while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
        // EXPLAIN QUERY PLAN columns: id(0), parent(1), notused(2), detail(3)
        const detail = std.mem.span(c.sqlite3_column_text(stmt, 3));
        stderr_writer.print("QUERY PLAN: {s}\n", .{detail}) catch |err| {
            std.log.err("failed to write query plan: {}", .{err});
        };
    }
    stderr_writer.flush() catch |err| std.log.err("failed to flush stderr after query plan: {}", .{err});
}

/// run(allocator, io, parsed, stderr_writer, stdout_writer, use_table) → void
/// Pre:  parsed contains a valid query; allocator and writers are valid
///       use_table is true when output should be formatted as a pretty table
/// Post: input from stdin/URL has been loaded (dispatched on parsed.input_format),
///       query executed, results written to stdout in parsed.output_format
///       On error, an "error: ..." message is written to stderr and process
///       exits with the appropriate ExitCode (1, 2, or 3)
/// loadPipelineInputs(allocator, io, db, parsed, stderr_writer) → usize
/// Pre:  db is open (in-memory or disk-backed)
/// Post: inputs from URL/files/stdin are loaded into named SQLite tables
///       returns total number of rows loaded
///       on fatal input error (bad URL, missing file), exits via fatal()
pub fn loadPipelineInputs(
    allocator: std.mem.Allocator,
    io: std.Io,
    db: *c.sqlite3,
    parsed: ParsedArgs,
    stderr_writer: *std.Io.Writer,
) usize {
    var total_rows: usize = 0;

    // Load each URL into its named table
    for (parsed.urls, 0..) |url_input, i| {
        var http_status: ?u16 = null;
        const fetch_result = http_mod.fetchUrl(allocator, io, url_input.url, url_input.headers, parsed.max_body_size, &http_status) catch |err| switch (err) {
            error.InvalidUrl => fatal("invalid URL: {s}", stderr_writer, .usage, .{url_input.url}),
            error.InvalidHttpHeader => fatal("invalid --http-header value", stderr_writer, .usage, .{}),
            error.UrlFetchFailed => if (http_status) |status|
                fatal("failed to fetch URL: {s} (HTTP {d})", stderr_writer, .usage, .{ url_input.url, status })
            else
                fatal("failed to fetch URL: {s}", stderr_writer, .usage, .{url_input.url}),
            else => fatal("URL fetch failed: {s}", stderr_writer, .usage, .{@errorName(err)}),
        };
        defer allocator.free(fetch_result.body);

        // Create reader from fetched body
        var body_reader = std.Io.Reader.fixed(fetch_result.body);

        // Use detected format unless -I explicitly provided for this URL or globally
        const input_format = if (url_input.format) |fmt| fmt else if (parsed.input_format_explicit) parsed.input_format else fetch_result.format;

        const table_name = url_input.table_name orelse blk: {
            var buf: [16]u8 = undefined;
            const written = std.fmt.bufPrint(&buf, "url{}", .{i}) catch unreachable;
            break :blk allocator.dupeZ(u8, written) catch unreachable;
        };
        const rows = loadInput(allocator, io, db, table_name, input_format, &body_reader, parsed, stderr_writer);
        total_rows += rows;
    }

    // Load each file argument into its named table
    for (parsed.files) |file_input| {
        var file_buf: [4096]u8 = undefined;
        const file = std.Io.Dir.openFile(std.Io.Dir.cwd(), io, file_input.path, .{}) catch |err|
            fatal("cannot open file '{s}': {s}", stderr_writer, .csv_error, .{ file_input.path, @errorName(err) });
        defer std.Io.File.close(file, io);
        var file_reader = std.Io.File.reader(file, io, &file_buf);
        const rows = loadInput(allocator, io, db, file_input.table_name, file_input.format, &file_reader.interface, parsed, stderr_writer);
        if (rows == 0) {
            fatal("empty input file: '{s}'", stderr_writer, .csv_error, .{file_input.path});
        }
        total_rows += rows;
    }

    // Load stdin as `stdin` if piped (and URLs/files exist), else `t`
    if (parsed.has_stdin) {
        var stdin_buf: [4096]u8 = undefined;
        var stdin_reader = std.Io.File.reader(std.Io.File.stdin(), io, &stdin_buf);
        const stdin_table = if (parsed.urls.len > 0 or parsed.files.len > 0) "stdin" else "t";
        const rows = loadInput(allocator, io, db, stdin_table, parsed.input_format, &stdin_reader.interface, parsed, stderr_writer);
        total_rows += rows;
    }

    // Warn when no rows were loaded — query referencing tables will fail
    if (total_rows == 0 and (parsed.has_stdin or parsed.files.len > 0 or parsed.urls.len > 0)) {
        stderr_writer.print("warning: no rows loaded — tables not created; query may fail\n", .{}) catch {};
    }

    return total_rows;
}

/// mainTableName(parsed) → []const u8
pub fn mainTableName(parsed: ParsedArgs) []const u8 {
    if (parsed.urls.len > 0) {
        if (parsed.urls[0].table_name) |name| return name;
        return "url0";
    }
    if (parsed.files.len > 0) return parsed.files[0].table_name;
    return "t";
}

fn run(
    allocator: std.mem.Allocator,
    io: std.Io,
    parsed: ParsedArgs,
    stderr_writer: *std.Io.Writer,
    stdout_writer: *std.Io.Writer,
    use_table: bool,
) void {
    const query = parsed.query;

    const db = sqlite_mod.openDb(parsed.disk, parsed.save_path, stderr_writer);
    defer _ = c.sqlite3_close(db);

    const start_ts = std.Io.Timestamp.now(io, .awake);
    const total_rows = loadPipelineInputs(allocator, io, db, parsed, stderr_writer);

    // Print row count and elapsed time to stderr when stderr is a TTY or --verbose is set.
    const is_tty = std.Io.File.isTty(std.Io.File.stderr(), io) catch false;
    if (!parsed.silent and (parsed.verbose or is_tty)) {
        const end_ts = std.Io.Timestamp.now(io, .awake);
        const elapsed_ns: i96 = end_ts.nanoseconds - start_ts.nanoseconds;
        const elapsed_ms: u64 = @intCast(@max(@as(i96, 0), @divTrunc(elapsed_ns, std.time.ns_per_ms)));
        var count_buf: [32]u8 = undefined;
        const count_str = fmtThousands(&count_buf, total_rows);
        const secs = elapsed_ms / 1000;
        const frac = (elapsed_ms % 1000) / 100;
        if (is_tty and total_rows >= progress_interval) {
            stderr_writer.writeAll("\r\x1b[K") catch |err| std.log.err("failed to clear progress line: {}", .{err});
        }
        stderr_writer.print("Loaded {s} rows in {d}.{d}s\n", .{ count_str, secs, frac }) catch |err| {
            std.log.err("failed to write row count: {}", .{err});
        };
        stderr_writer.flush() catch |err| std.log.err("failed to flush stderr: {}", .{err});
    }

    const main_table = mainTableName(parsed);

    // Print query plan to stderr when --explain is set
    if (parsed.explain) {
        printQueryPlan(allocator, db, query, main_table, stderr_writer);
    }

    execQuery(allocator, db, query, stdout_writer, parsed.header, parsed.output_format, parsed.xml_root, parsed.xml_row, parsed.sql_table, parsed.html_class, parsed.null_value, use_table) catch {
        stdout_writer.flush() catch |err| std.log.err("failed to flush output before fatal: {}", .{err});
        sqlite_mod.fatalSqlWithContext(allocator, db, main_table, std.mem.span(c.sqlite3_errmsg(db)), stderr_writer);
    };
}

pub fn main(init: std.process.Init.Minimal) void {
    // ponytail: c_allocator; DebugAllocator deinit was _ = discarded, leak detection was off
    const allocator = std.heap.c_allocator;

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

    const args_result = parseArgs(args_arena.allocator(), args) catch |err| {
        switch (err) {
            error.IncompatibleFlags => fatal("--header cannot be combined with non-CSV/TSV/HTML output format", stderr_writer, .usage, .{}),
            error.InvalidUrl => fatal("--url requires a non-empty HTTP/HTTPS URL", stderr_writer, .usage, .{}),
            error.InvalidHttpHeader => fatal("--http-header requires a non-empty 'Name: Value' header", stderr_writer, .usage, .{}),
            error.InvalidMaxBodySize => fatal("--max-body-size requires a positive integer", stderr_writer, .usage, .{}),
            error.HttpFlagsRequireUrl => fatal("--http-header and --max-body-size require --url", stderr_writer, .usage, .{}),
            error.UrlIncompatibleMode => fatal("--url cannot be combined with --columns, --validate, or --sample", stderr_writer, .usage, .{}),
            error.InvalidInspectMode => fatal("unknown inspect mode; supported: columns, validate, sample, stats, schema", stderr_writer, .usage, .{}),
            error.InspectWithQuery => fatal("--inspect cannot be combined with a query argument", stderr_writer, .usage, .{}),
            error.InspectWithOutput => fatal("--inspect cannot be combined with --output", stderr_writer, .usage, .{}),
            error.InspectWithExplain => fatal("--inspect cannot be combined with --explain", stderr_writer, .usage, .{}),
            error.InspectSampleWithJson => fatal("--inspect sample cannot be combined with --json or a JSON output format", stderr_writer, .usage, .{}),
            error.ExplainWithOutput => fatal("--explain cannot be combined with --output", stderr_writer, .usage, .{}),
            error.SilentVerboseConflict => fatal("--silent cannot be combined with --verbose", stderr_writer, .usage, .{}),
            error.InvalidMaxRows => fatal("--max-rows must be a positive integer", stderr_writer, .usage, .{}),
            error.InvalidInputFormat => fatal("unknown input format; supported: csv, tsv, json, ndjson, xml, yaml, parquet", stderr_writer, .usage, .{}),
            error.InvalidOutputFormat => fatal("unknown output format; supported: csv, tsv, json, ndjson, xml, markdown (md), html, sql", stderr_writer, .usage, .{}),
            // ponytail: ColumnsWithQuery, ValidateWithQuery handled by InspectWithQuery above
            error.InvalidOutputPath => fatal("--output requires a non-empty file path", stderr_writer, .usage, .{}),
            error.InvalidSampleCount => fatal("--sample requires a positive integer value", stderr_writer, .usage, .{}),
            error.MissingQuery => {
                stderr_writer.writeAll("error: no SQL query provided\n") catch |werr| std.log.err("failed to write error: {}", .{werr});
                // Fall through to printUsage + exit below
            },
            error.InvalidQueryFile => fatal("-f/--file requires a non-empty file path", stderr_writer, .usage, .{}),
            error.MultipleQueryFiles => fatal("only one -f/--file flag is allowed", stderr_writer, .usage, .{}),
            error.MissingSqlTableValue => fatal("--sql-table requires a value", stderr_writer, .usage, .{}),
            error.MissingXmlFlagValue => fatal("--xml-root and --xml-row require a value", stderr_writer, .usage, .{}),
            error.MissingJsonFlagValue => fatal("--json-path requires a value", stderr_writer, .usage, .{}),
            error.JsonPathRequiresJson => fatal("--json-path requires -I json", stderr_writer, .usage, .{}),
            error.InvalidXmlName => fatal("--xml-root and --xml-row must be valid XML element names (letter/underscore first, then letters/digits/-/._/:)", stderr_writer, .usage, .{}),
            error.DuplicateTableName => fatal("duplicate table name — file arguments must have unique basenames", stderr_writer, .usage, .{}),
            error.TableWithNonCsv => fatal("--table requires CSV or TSV output format (not compatible with --json, -O json, etc.)", stderr_writer, .usage, .{}),
            // ponytail: ExplainWithFlags handled by InspectWithExplain above
            error.InvalidSavePath => fatal("--save requires a non-empty file path", stderr_writer, .usage, .{}),
            error.SaveIncompatibleMode => fatal("--save cannot be combined with special modes", stderr_writer, .usage, .{}),
            error.SaveIncompatibleDisk => fatal("--save implies --disk; remove --disk", stderr_writer, .usage, .{}),
            error.MissingNullValue => fatal("--null-value requires a value", stderr_writer, .usage, .{}),
            error.MissingHtmlClassValue => fatal("--html-class requires a value", stderr_writer, .usage, .{}),
            error.InvalidCompletionsShell => fatal("unknown shell; supported: bash, zsh, fish", stderr_writer, .usage, .{}),
            error.ReplIncompatibleMode => fatal("--repl cannot be combined with other special modes", stderr_writer, .usage, .{}),
            error.ReplWithQueryFile => fatal("--repl cannot be combined with -f/--file", stderr_writer, .usage, .{}),
            error.ReplWithOutput => fatal("--repl cannot be combined with --output", stderr_writer, .usage, .{}),
            error.ReplIncompatibleExplain => fatal("--repl cannot be combined with --explain", stderr_writer, .usage, .{}),
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
        .inspect => |parsed| {
            const inspect_args = parsed.inspect_args orelse unreachable;
            // Print deprecation warning if old flag was used
            if (inspect_args.deprecated) {
                const mode_str = @tagName(inspect_args.mode);
                stderr_writer.print("warning: --{s} is deprecated, use --inspect {s}\n", .{ mode_str, mode_str }) catch {};
                stderr_writer.flush() catch {};
            }
            inspect_mode.runInspect(allocator, io.io(), inspect_args.mode, parsed, stderr_writer, stdout_writer);
            stdout_file_writer.flush() catch |err| {
                std.log.err("failed to flush stdout: {}", .{err});
            };
            stderr_file_writer.flush() catch |err| {
                std.log.err("failed to flush stderr: {}", .{err});
            };
        },
        .completions => |comp_args| {
            completions_mod.generateCompletions(comp_args.shell, stdout_writer) catch |err| {
                std.log.err("failed to write completions: {}", .{err});
            };
            stdout_file_writer.flush() catch |err| {
                std.log.err("failed to flush stdout: {}", .{err});
            };
            stderr_file_writer.flush() catch |err| {
                std.log.err("failed to flush stderr: {}", .{err});
            };
        },
        .repl => |mut_parsed| {
            var parsed = mut_parsed;
            parsed.has_stdin = if (parsed.no_stdin) false else !(std.Io.File.isTty(std.Io.File.stdin(), io.io()) catch false);
            // Read query from file if -f/--file was used.
            if (parsed.query_file) |path| {
                const contents = std.Io.Dir.cwd().readFileAlloc(io.io(), path, args_arena.allocator(), .limited(10 * 1024 * 1024)) catch |err| {
                    fatal("cannot read query file '{s}': {s}", stderr_writer, .usage, .{ path, @errorName(err) });
                };
                const trimmed = std.mem.trim(u8, contents, " \t\r\n");
                if (trimmed.len == 0) {
                    fatal("query file '{s}' is empty", stderr_writer, .usage, .{path});
                }
                parsed.query = trimmed;
            }
            // `stdin` is reserved for stdin input when URLs/files exist.
            if (parsed.has_stdin or parsed.urls.len > 0) {
                for (parsed.files) |f| {
                    if (std.mem.eql(u8, f.table_name, "stdin")) {
                        fatal("duplicate table name — file arguments must have unique basenames", stderr_writer, .usage, .{});
                    }
                }
                for (parsed.urls) |url_input| {
                    const table_name = url_input.table_name orelse "url0";
                    if (std.mem.eql(u8, table_name, "stdin")) {
                        fatal("duplicate table name — URL table name conflicts with stdin", stderr_writer, .usage, .{});
                    }
                }
            }
            // Resolve table mode: auto-detect from stdout TTY when not explicitly set.
            const stdout_is_tty = std.Io.File.isTty(std.Io.File.stdout(), io.io()) catch false;
            const use_table_repl = switch (parsed.table_mode) {
                .always => true,
                .never => false,
                .auto => stdout_is_tty and (parsed.output_format == .csv or parsed.output_format == .tsv),
            };
            repl_mode.runRepl(allocator, io.io(), parsed, stderr_writer, stdout_writer, use_table_repl);
            stdout_file_writer.flush() catch |err| {
                std.log.err("failed to flush stdout: {}", .{err});
            };
            stderr_file_writer.flush() catch |err| {
                std.log.err("failed to flush stderr: {}", .{err});
            };
        },
        .parsed => |mut_parsed| {
            var parsed = mut_parsed;
            parsed.has_stdin = if (parsed.no_stdin) false else !(std.Io.File.isTty(std.Io.File.stdin(), io.io()) catch false);
            // Read query from file if -f/--file was used.
            // Arena-allocated to match the lifetime of parsed args.
            if (parsed.query_file) |path| {
                const contents = std.Io.Dir.cwd().readFileAlloc(io.io(), path, args_arena.allocator(), .limited(10 * 1024 * 1024)) catch |err| {
                    fatal("cannot read query file '{s}': {s}", stderr_writer, .usage, .{ path, @errorName(err) });
                };
                const trimmed = std.mem.trim(u8, contents, " \t\r\n");
                if (trimmed.len == 0) {
                    fatal("query file '{s}' is empty", stderr_writer, .usage, .{path});
                }
                parsed.query = trimmed;
            }
            // `stdin` is reserved for stdin input when URLs/files exist.
            if (parsed.has_stdin or parsed.urls.len > 0) {
                for (parsed.files) |f| {
                    if (std.mem.eql(u8, f.table_name, "stdin")) {
                        fatal("duplicate table name — file arguments must have unique basenames", stderr_writer, .usage, .{});
                    }
                }
                for (parsed.urls) |url_input| {
                    const table_name = url_input.table_name orelse "url0";
                    if (std.mem.eql(u8, table_name, "stdin")) {
                        fatal("duplicate table name — URL table name conflicts with stdin", stderr_writer, .usage, .{});
                    }
                }
            }
            // Resolve table mode: auto-detect from stdout TTY when not explicitly set.
            // Table output only applies when writing to stdout (not --output to a file)
            // and only for CSV/TSV output formats (not JSON/XML).
            const stdout_is_tty = std.Io.File.isTty(std.Io.File.stdout(), io.io()) catch false;
            const use_table_stdout = switch (parsed.table_mode) {
                .always => true,
                .never => false,
                .auto => stdout_is_tty and (parsed.output_format == .csv or parsed.output_format == .tsv),
            };
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
                // Table mode is disabled when writing to a file
                run(allocator, io.io(), parsed, stderr_writer, &output_file_writer.interface, false);
                output_file_writer.flush() catch |err| {
                    std.log.err("failed to flush output file: {}", .{err});
                };
            } else {
                run(allocator, io.io(), parsed, stderr_writer, stdout_writer, use_table_stdout);
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
