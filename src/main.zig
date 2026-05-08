const std = @import("std");
const c = @import("c");
const csv = @import("csv.zig");
const json = @import("json.zig");
const xml = @import("xml.zig");
const format = @import("format.zig");
const build_options = @import("build_options");
const args_mod = @import("args.zig");
const sqlite_mod = @import("sqlite.zig");
const loader = @import("loader.zig");

const ColumnType = sqlite_mod.ColumnType;

const VERSION: []const u8 = build_options.version;

const SqlPipeError = args_mod.SqlPipeError;
const ParsedArgs = args_mod.ParsedArgs;
const ColumnsArgs = args_mod.ColumnsArgs;
const ValidateArgs = args_mod.ValidateArgs;
const SampleArgs = args_mod.SampleArgs;
const ArgsResult = args_mod.ArgsResult;
const parseArgs = args_mod.parseArgs;
const printUsage = args_mod.printUsage;

const inferTypes = loader.inferTypes;
const parseHeader = loader.parseHeader;
const insertRowTyped = loader.insertRowTyped;
const fmtThousands = loader.fmtThousands;
const printProgress = loader.printProgress;
const loadCsvInput = loader.loadCsvInput;
const inference_buffer_size = loader.inference_buffer_size;
const progress_interval = loader.progress_interval;

/// Structured exit codes for scripting.
///   0 = success
///   1 = usage error (missing query, bad flag)
///   2 = CSV parse error
///   3 = SQL error (sqlite3 error)
const ExitCode = enum(u8) {
    success = 0,
    usage = 1,
    csv_error = 2,
    sql_error = 3,
};

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

/// fatal(writer, code, comptime fmt, args) → noreturn
/// Pre:  writer is stderr, code is non-zero ExitCode
/// Post: "error: <message>\n" written to stderr, process exits with code
fn fatal(comptime fmt: []const u8, writer: *std.Io.Writer, code: ExitCode, args: anytype) noreturn {
    writer.print("error: " ++ fmt ++ "\n", args) catch |err| {
        std.log.err("failed to write error message: {}", .{err});
    };
    writer.flush() catch |err| std.log.err("failed to flush: {}", .{err});
    std.process.exit(@intFromEnum(code));
}

/// runColumns(allocator, io, args, stderr_writer, stdout_writer) → void
/// Pre:  args is valid; allocator and writers are valid
/// Post: column names from the input header (CSV/JSON/NDJSON) are written to stdout,
///       one per line; when args.verbose is true each line has format "<name> <TYPE>"
///       (CSV only — JSON/NDJSON always show TEXT); exits 0 on success, 2 on parse error
fn runColumns(
    allocator: std.mem.Allocator,
    io: std.Io,
    args: ColumnsArgs,
    stderr_writer: *std.Io.Writer,
    stdout_writer: *std.Io.Writer,
) void {
    switch (args.input_format) {
        .csv, .tsv => {
            const col_delim: []const u8 = if (args.input_format == .tsv) "\t" else args.delimiter;
            var stdin_buf: [4096]u8 = undefined;
            var stdin_file_reader = std.Io.File.reader(std.Io.File.stdin(), io, &stdin_buf);
            var csv_reader = csv.csvReaderWithDelimiter(allocator, &stdin_file_reader.interface, col_delim);

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

            if (args.verbose) {
                var row_buffer: std.ArrayList([][]u8) = .empty;
                defer {
                    for (row_buffer.items) |row| csv_reader.freeRecord(row);
                    row_buffer.deinit(allocator);
                }
                var data_row: usize = 1;
                while (row_buffer.items.len < inference_buffer_size) {
                    data_row += 1;
                    const rec = csv_reader.nextRecord() catch |err| switch (err) {
                        error.UnterminatedQuotedField => fatal(
                            "row {d}: unterminated quoted field",
                            stderr_writer,
                            .csv_error,
                            .{data_row},
                        ),
                        else => fatal("row {d}: failed to parse CSV", stderr_writer, .csv_error, .{data_row}),
                    } orelse break;
                    if (rec.len == 0) {
                        csv_reader.freeRecord(rec);
                        continue;
                    }
                    row_buffer.append(allocator, rec) catch
                        fatal("out of memory while buffering rows", stderr_writer, .csv_error, .{});
                }
                const types = inferTypes(allocator, row_buffer.items, cols.len) catch
                    fatal("out of memory during type inference", stderr_writer, .csv_error, .{});
                defer allocator.free(types);
                for (cols, types) |col, t| {
                    stdout_writer.print("{s} {s}\n", .{ col, @tagName(t) }) catch |err| {
                        std.log.err("failed to write output: {}", .{err});
                    };
                }
            } else {
                for (cols) |col| {
                    stdout_writer.print("{s}\n", .{col}) catch |err| {
                        std.log.err("failed to write output: {}", .{err});
                    };
                }
            }
        },
        .json => {
            var stdin_buf: [4096]u8 = undefined;
            var stdin_file_reader = std.Io.File.reader(std.Io.File.stdin(), io, &stdin_buf);

            var buf: std.ArrayList(u8) = .empty;
            defer buf.deinit(allocator);
            while (true) {
                const byte = stdin_file_reader.interface.takeByte() catch |err| switch (err) {
                    error.EndOfStream => break,
                    error.ReadFailed => fatal("failed to read JSON input", stderr_writer, .csv_error, .{}),
                };
                buf.append(allocator, byte) catch fatal("out of memory reading JSON", stderr_writer, .csv_error, .{});
            }
            if (buf.items.len == 0) fatal("empty input", stderr_writer, .csv_error, .{});

            var parsed = std.json.parseFromSlice(std.json.Value, allocator, buf.items, .{}) catch
                fatal("failed to parse JSON input", stderr_writer, .csv_error, .{});
            defer parsed.deinit();

            const array = switch (parsed.value) {
                .array => |a| a,
                else => fatal("JSON input must be an array of objects", stderr_writer, .csv_error, .{}),
            };
            if (array.items.len == 0) fatal("empty JSON array: cannot determine column names", stderr_writer, .csv_error, .{});

            const first_obj = switch (array.items[0]) {
                .object => |o| o,
                else => fatal("JSON array elements must be objects", stderr_writer, .csv_error, .{}),
            };

            var ki = first_obj.iterator();
            while (ki.next()) |entry| {
                if (args.verbose) {
                    stdout_writer.print("{s} TEXT\n", .{entry.key_ptr.*}) catch |err| {
                        std.log.err("failed to write output: {}", .{err});
                    };
                } else {
                    stdout_writer.print("{s}\n", .{entry.key_ptr.*}) catch |err| {
                        std.log.err("failed to write output: {}", .{err});
                    };
                }
            }
        },
        .ndjson => {
            var stdin_buf: [4096]u8 = undefined;
            var stdin_file_reader = std.Io.File.reader(std.Io.File.stdin(), io, &stdin_buf);

            // Read until we find a non-empty line
            var line_num: usize = 0;
            while (true) {
                line_num += 1;
                const line = json.readLine(allocator, &stdin_file_reader.interface) catch |err| switch (err) {
                    error.OutOfMemory => fatal("out of memory reading NDJSON", stderr_writer, .csv_error, .{}),
                    error.ReadFailed => fatal("line {d}: failed to read NDJSON", stderr_writer, .csv_error, .{line_num}),
                } orelse fatal("empty NDJSON input", stderr_writer, .csv_error, .{});
                defer allocator.free(line);

                const trimmed = std.mem.trim(u8, line, " \t\r");
                if (trimmed.len == 0) { line_num -= 1; continue; }

                var parsed = std.json.parseFromSlice(std.json.Value, allocator, trimmed, .{}) catch
                    fatal("line 1: failed to parse NDJSON", stderr_writer, .csv_error, .{});
                defer parsed.deinit();

                const obj = switch (parsed.value) {
                    .object => |o| o,
                    else => fatal("line 1: NDJSON element must be a JSON object", stderr_writer, .csv_error, .{}),
                };

                var ki = obj.iterator();
                while (ki.next()) |entry| {
                    if (args.verbose) {
                        stdout_writer.print("{s} TEXT\n", .{entry.key_ptr.*}) catch |err| {
                            std.log.err("failed to write output: {}", .{err});
                        };
                    } else {
                        stdout_writer.print("{s}\n", .{entry.key_ptr.*}) catch |err| {
                            std.log.err("failed to write output: {}", .{err});
                        };
                    }
                }
                break;
            }
        },
        .xml => {
            var stdin_buf: [4096]u8 = undefined;
            var stdin_file_reader = std.Io.File.reader(std.Io.File.stdin(), io, &stdin_buf);

            const names = xml.getXmlColumnNames(allocator, &stdin_file_reader.interface, args.xml_root_input, args.xml_row_input, stderr_writer);
            defer {
                for (names) |name| allocator.free(name);
                allocator.free(names);
            }
            for (names) |name| {
                if (args.verbose) {
                    stdout_writer.print("{s} TEXT\n", .{name}) catch |err| {
                        std.log.err("failed to write output: {}", .{err});
                    };
                } else {
                    stdout_writer.print("{s}\n", .{name}) catch |err| {
                        std.log.err("failed to write output: {}", .{err});
                    };
                }
            }
        },
    }
}

/// runValidate(allocator, io, args, stderr_writer, stdout_writer) → void
/// Pre:  args is valid; allocator and writers are valid
/// Post: the entire input has been parsed (CSV, TSV, JSON, or NDJSON);
///       on success prints "OK: <n> rows, <m> columns (<col> <TYPE>, ...)" to stdout.
///       On parse error, prints the error message to stderr and exits 2.
fn runValidate(
    allocator: std.mem.Allocator,
    io: std.Io,
    args: ValidateArgs,
    stderr_writer: *std.Io.Writer,
    stdout_writer: *std.Io.Writer,
) void {
    switch (args.input_format) {
        .csv, .tsv => {
            const col_delim: []const u8 = if (args.input_format == .tsv) "\t" else args.delimiter;
            var stdin_buf: [4096]u8 = undefined;
            var stdin_file_reader = std.Io.File.reader(std.Io.File.stdin(), io, &stdin_buf);
            var csv_reader = csv.csvReaderWithDelimiter(allocator, &stdin_file_reader.interface, col_delim);

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
            var csv_row_count: usize = 1; // header already read
            var data_row_count: usize = 0;

            var row_buffer: std.ArrayList([][]u8) = .empty;
            defer {
                for (row_buffer.items) |row| csv_reader.freeRecord(row);
                row_buffer.deinit(allocator);
            }

            // Buffer up to inference_buffer_size rows for type inference
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
                data_row_count += 1;
                row_buffer.append(allocator, rec) catch
                    fatal("out of memory while buffering rows", stderr_writer, .csv_error, .{});
            }

            const types: []ColumnType = if (args.type_inference) blk: {
                break :blk inferTypes(allocator, row_buffer.items, num_cols) catch
                    fatal("out of memory during type inference", stderr_writer, .csv_error, .{});
            } else blk: {
                const t = allocator.alloc(ColumnType, num_cols) catch
                    fatal("out of memory", stderr_writer, .csv_error, .{});
                @memset(t, .TEXT);
                break :blk t;
            };
            defer allocator.free(types);

            // Stream remaining rows and count them
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
                data_row_count += 1;
            }

            var count_buf: [32]u8 = undefined;
            const count_str = fmtThousands(&count_buf, data_row_count);

            stdout_writer.print("OK: {s} rows, {d} columns (", .{ count_str, num_cols }) catch |err| {
                std.log.err("failed to write output: {}", .{err});
                std.process.exit(@intFromEnum(ExitCode.usage));
            };

            for (cols, types, 0..) |col, t, i| {
                if (i > 0) {
                    stdout_writer.writeAll(", ") catch |err| {
                        std.log.err("failed to write output: {}", .{err});
                        std.process.exit(@intFromEnum(ExitCode.usage));
                    };
                }
                stdout_writer.print("{s} {s}", .{ col, @tagName(t) }) catch |err| {
                    std.log.err("failed to write output: {}", .{err});
                    std.process.exit(@intFromEnum(ExitCode.usage));
                };
            }
            stdout_writer.writeAll(")\n") catch |err| {
                std.log.err("failed to write output: {}", .{err});
                std.process.exit(@intFromEnum(ExitCode.usage));
            };
        },
        .json => {
            var stdin_buf: [4096]u8 = undefined;
            var stdin_file_reader = std.Io.File.reader(std.Io.File.stdin(), io, &stdin_buf);

            var buf: std.ArrayList(u8) = .empty;
            defer buf.deinit(allocator);
            while (true) {
                const byte = stdin_file_reader.interface.takeByte() catch |err| switch (err) {
                    error.EndOfStream => break,
                    error.ReadFailed => fatal("failed to read JSON input", stderr_writer, .csv_error, .{}),
                };
                buf.append(allocator, byte) catch fatal("out of memory reading JSON", stderr_writer, .csv_error, .{});
            }
            if (buf.items.len == 0) fatal("empty input", stderr_writer, .csv_error, .{});

            var parsed = std.json.parseFromSlice(std.json.Value, allocator, buf.items, .{}) catch
                fatal("failed to parse JSON input", stderr_writer, .csv_error, .{});
            defer parsed.deinit();

            const array = switch (parsed.value) {
                .array => |a| a,
                else => fatal("JSON input must be an array of objects", stderr_writer, .csv_error, .{}),
            };
            if (array.items.len == 0) fatal("empty JSON array: cannot determine column names", stderr_writer, .csv_error, .{});

            const first_obj = switch (array.items[0]) {
                .object => |o| o,
                else => fatal("JSON array elements must be objects", stderr_writer, .csv_error, .{}),
            };

            var num_cols: usize = 0;
            var ki = first_obj.iterator();
            while (ki.next()) |_| num_cols += 1;

            var count_buf: [32]u8 = undefined;
            const count_str = fmtThousands(&count_buf, array.items.len);
            stdout_writer.print("OK: {s} rows, {d} columns (", .{ count_str, num_cols }) catch |err| {
                std.log.err("failed to write output: {}", .{err});
                std.process.exit(@intFromEnum(ExitCode.usage));
            };
            ki = first_obj.iterator();
            var col_i: usize = 0;
            while (ki.next()) |entry| : (col_i += 1) {
                if (col_i > 0) stdout_writer.writeAll(", ") catch |err| {
                    std.log.err("failed to write output: {}", .{err});
                    std.process.exit(@intFromEnum(ExitCode.usage));
                };
                stdout_writer.print("{s} TEXT", .{entry.key_ptr.*}) catch |err| {
                    std.log.err("failed to write output: {}", .{err});
                    std.process.exit(@intFromEnum(ExitCode.usage));
                };
            }
            stdout_writer.writeAll(")\n") catch |err| {
                std.log.err("failed to write output: {}", .{err});
                std.process.exit(@intFromEnum(ExitCode.usage));
            };
        },
        .ndjson => {
            var stdin_buf: [4096]u8 = undefined;
            var stdin_file_reader = std.Io.File.reader(std.Io.File.stdin(), io, &stdin_buf);

            var line_num: usize = 0;
            var row_count: usize = 0;
            var cols_owned: ?[][]u8 = null;
            defer if (cols_owned) |cs| {
                for (cs) |col| allocator.free(col);
                allocator.free(cs);
            };

            while (true) {
                line_num += 1;
                const line = json.readLine(allocator, &stdin_file_reader.interface) catch |err| switch (err) {
                    error.OutOfMemory => fatal("out of memory reading NDJSON", stderr_writer, .csv_error, .{}),
                    error.ReadFailed => fatal("line {d}: failed to read NDJSON", stderr_writer, .csv_error, .{line_num}),
                } orelse break;
                defer allocator.free(line);

                const trimmed = std.mem.trim(u8, line, " \t\r");
                if (trimmed.len == 0) {
                    line_num -= 1;
                    continue;
                }

                var parsed_line = std.json.parseFromSlice(std.json.Value, allocator, trimmed, .{}) catch
                    fatal("line {d}: failed to parse NDJSON", stderr_writer, .csv_error, .{line_num});
                defer parsed_line.deinit();

                const obj = switch (parsed_line.value) {
                    .object => |o| o,
                    else => fatal("line {d}: NDJSON element must be a JSON object", stderr_writer, .csv_error, .{line_num}),
                };

                if (cols_owned == null) {
                    var col_list: std.ArrayList([]u8) = .empty;
                    errdefer {
                        for (col_list.items) |col| allocator.free(col);
                        col_list.deinit(allocator);
                    }
                    var ki = obj.iterator();
                    while (ki.next()) |entry| {
                        const owned_key = allocator.dupe(u8, entry.key_ptr.*) catch
                            fatal("out of memory building column list", stderr_writer, .csv_error, .{});
                        col_list.append(allocator, owned_key) catch
                            fatal("out of memory building column list", stderr_writer, .csv_error, .{});
                    }
                    if (col_list.items.len == 0)
                        fatal("line 1: first NDJSON object has no keys", stderr_writer, .csv_error, .{});
                    cols_owned = col_list.toOwnedSlice(allocator) catch
                        fatal("out of memory", stderr_writer, .csv_error, .{});
                }
                row_count += 1;
            }

            if (cols_owned == null) fatal("empty NDJSON input", stderr_writer, .csv_error, .{});

            const cols = cols_owned.?;
            var count_buf: [32]u8 = undefined;
            const count_str = fmtThousands(&count_buf, row_count);
            stdout_writer.print("OK: {s} rows, {d} columns (", .{ count_str, cols.len }) catch |err| {
                std.log.err("failed to write output: {}", .{err});
                std.process.exit(@intFromEnum(ExitCode.usage));
            };
            for (cols, 0..) |col, i| {
                if (i > 0) stdout_writer.writeAll(", ") catch |err| {
                    std.log.err("failed to write output: {}", .{err});
                    std.process.exit(@intFromEnum(ExitCode.usage));
                };
                stdout_writer.print("{s} TEXT", .{col}) catch |err| {
                    std.log.err("failed to write output: {}", .{err});
                    std.process.exit(@intFromEnum(ExitCode.usage));
                };
            }
            stdout_writer.writeAll(")\n") catch |err| {
                std.log.err("failed to write output: {}", .{err});
                std.process.exit(@intFromEnum(ExitCode.usage));
            };
        },
        .xml => {
            var stdin_buf: [4096]u8 = undefined;
            var stdin_file_reader = std.Io.File.reader(std.Io.File.stdin(), io, &stdin_buf);

            const summary = xml.summarizeXml(allocator, &stdin_file_reader.interface, args.xml_root_input, args.xml_row_input, stderr_writer);
            defer {
                for (summary.col_names) |name| allocator.free(name);
                allocator.free(summary.col_names);
            }

            var count_buf: [32]u8 = undefined;
            const count_str = fmtThousands(&count_buf, summary.row_count);
            stdout_writer.print("OK: {s} rows, {d} columns (", .{ count_str, summary.col_names.len }) catch |err| {
                std.log.err("failed to write output: {}", .{err});
                std.process.exit(@intFromEnum(ExitCode.usage));
            };
            for (summary.col_names, 0..) |name, i| {
                if (i > 0) stdout_writer.writeAll(", ") catch |err| {
                    std.log.err("failed to write output: {}", .{err});
                    std.process.exit(@intFromEnum(ExitCode.usage));
                };
                stdout_writer.print("{s} TEXT", .{name}) catch |err| {
                    std.log.err("failed to write output: {}", .{err});
                    std.process.exit(@intFromEnum(ExitCode.usage));
                };
            }
            stdout_writer.writeAll(")\n") catch |err| {
                std.log.err("failed to write output: {}", .{err});
                std.process.exit(@intFromEnum(ExitCode.usage));
            };
        },
    }
}

/// runSample(allocator, io, args, stderr_writer, stdout_writer) → void
/// Pre:  args is valid; allocator and writers are valid; input_format is csv or tsv
/// Post: a schema comment block is written to stderr (column names + inferred types,
///       or all TEXT if args.type_inference is false, each line prefixed with "#") and
///       a header row + first args.n data rows are written to stdout as delimited text.
///       Exits 2 on parse error, 1 on stdout write error. No query required.
fn runSample(
    allocator: std.mem.Allocator,
    io: std.Io,
    args: SampleArgs,
    stderr_writer: *std.Io.Writer,
    stdout_writer: *std.Io.Writer,
) void {
    switch (args.input_format) {
        .json, .ndjson, .xml => fatal(
            "--sample is only supported with CSV and TSV input",
            stderr_writer,
            .usage,
            .{},
        ),
        .csv, .tsv => {
            const col_delim: []const u8 = if (args.input_format == .tsv) "\t" else args.delimiter;
            var stdin_buf: [4096]u8 = undefined;
            var stdin_file_reader = std.Io.File.reader(std.Io.File.stdin(), io, &stdin_buf);
            var csv_reader = csv.csvReaderWithDelimiter(allocator, &stdin_file_reader.interface, col_delim);

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

            // Buffer max(inference_buffer_size, n) rows for type inference
            const buf_size = @max(inference_buffer_size, args.n);
            var row_buffer: std.ArrayList([][]u8) = .empty;
            defer {
                for (row_buffer.items) |row| csv_reader.freeRecord(row);
                row_buffer.deinit(allocator);
            }

            var csv_row_count: usize = 1;
            // Loop invariant I: row_buffer contains all non-empty data rows read so far (up to buf_size)
            // Bounding function: buf_size - row_buffer.items.len
            while (row_buffer.items.len < buf_size) {
                const rec = csv_reader.nextRecord() catch |err| switch (err) {
                    error.UnterminatedQuotedField => fatal(
                        "row {d}: unterminated quoted field",
                        stderr_writer,
                        .csv_error,
                        .{csv_row_count + 1},
                    ),
                    else => fatal("row {d}: failed to parse CSV", stderr_writer, .csv_error, .{csv_row_count + 1}),
                } orelse break;
                csv_row_count += 1;
                if (rec.len == 0) {
                    csv_reader.freeRecord(rec);
                    continue;
                }
                row_buffer.append(allocator, rec) catch
                    fatal("out of memory while buffering rows", stderr_writer, .csv_error, .{});
            }

            const types: []ColumnType = if (args.type_inference) blk: {
                break :blk inferTypes(allocator, row_buffer.items, cols.len) catch
                    fatal("out of memory during type inference", stderr_writer, .csv_error, .{});
            } else blk: {
                const t = allocator.alloc(ColumnType, cols.len) catch
                    fatal("out of memory", stderr_writer, .csv_error, .{});
                @memset(t, .TEXT);
                break :blk t;
            };
            defer allocator.free(types);

            // ─── Print schema block to stderr ─────────────────────────────────────
            // Compute max column name width for aligned output
            var max_col_width: usize = 0;
            for (cols) |col| max_col_width = @max(max_col_width, col.len);

            stderr_writer.print("# Schema ({d} columns):\n", .{cols.len}) catch |err| {
                std.log.err("failed to write schema: {}", .{err});
            };
            // Loop invariant I: cols[0..i] have been printed with aligned type annotation
            // Bounding function: cols.len - i
            for (cols, types) |col, t| {
                stderr_writer.writeAll("#   ") catch |err| {
                    std.log.err("failed to write schema: {}", .{err});
                };
                stderr_writer.writeAll(col) catch |err| {
                    std.log.err("failed to write schema: {}", .{err});
                };
                // Pad to max_col_width + 2 spaces before the type
                var p: usize = col.len;
                while (p < max_col_width + 2) : (p += 1) {
                    stderr_writer.writeByte(' ') catch |err| {
                        std.log.err("failed to write schema: {}", .{err});
                    };
                }
                stderr_writer.print("{s}\n", .{@tagName(t)}) catch |err| {
                    std.log.err("failed to write schema: {}", .{err});
                };
            }
            stderr_writer.flush() catch |err| std.log.err("failed to flush stderr: {}", .{err});

            // ─── Print header row to stdout ────────────────────────────────────────
            // Loop invariant I: cols[0..i] names have been written, separated by col_delim
            // Bounding function: cols.len - i
            for (cols, 0..) |col, i| {
                if (i > 0) stdout_writer.writeAll(col_delim) catch
                    fatal("failed to write header", stderr_writer, .csv_error, .{});
                format.writeField(stdout_writer, col, col_delim) catch
                    fatal("failed to write header", stderr_writer, .csv_error, .{});
            }
            stdout_writer.writeByte('\n') catch
                fatal("failed to write header newline", stderr_writer, .csv_error, .{});

            // ─── Print first n data rows to stdout ────────────────────────────────
            const rows_to_print = @min(args.n, row_buffer.items.len);
            // Loop invariant I: row_buffer[0..r] have been printed as delimited rows
            // Bounding function: rows_to_print - r
            for (row_buffer.items[0..rows_to_print]) |row| {
                var col_idx: usize = 0;
                // Loop invariant I: cols[0..col_idx] fields have been written for this row
                // Bounding function: cols.len - col_idx
                while (col_idx < cols.len) : (col_idx += 1) {
                    if (col_idx > 0) stdout_writer.writeAll(col_delim) catch
                        fatal("failed to write field separator", stderr_writer, .csv_error, .{});
                    const val: []const u8 = if (col_idx < row.len) row[col_idx] else "";
                    format.writeField(stdout_writer, val, col_delim) catch
                        fatal("failed to write field", stderr_writer, .csv_error, .{});
                }
                stdout_writer.writeByte('\n') catch
                    fatal("failed to write row newline", stderr_writer, .csv_error, .{});
            }
        },
    }
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

    const db = sqlite_mod.openDb(stderr_writer);
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
            error.IncompatibleFlags => {
                stderr_writer.writeAll(
                    "error: --header cannot be combined with non-CSV/TSV output format\n",
                ) catch |werr| std.log.err("failed to write error message: {}", .{werr});
                stderr_writer.flush() catch |ferr| std.log.err("failed to flush: {}", .{ferr});
                std.process.exit(@intFromEnum(ExitCode.usage));
            },
            error.SilentVerboseConflict => {
                stderr_writer.writeAll(
                    "error: --silent cannot be combined with --verbose\n",
                ) catch |werr| std.log.err("failed to write error message: {}", .{werr});
                stderr_writer.flush() catch |ferr| std.log.err("failed to flush: {}", .{ferr});
                std.process.exit(@intFromEnum(ExitCode.usage));
            },
            error.InvalidMaxRows => {
                stderr_writer.writeAll("error: --max-rows must be a positive integer\n") catch |werr| {
                    std.log.err("failed to write error message: {}", .{werr});
                };
                stderr_writer.flush() catch |ferr| std.log.err("failed to flush: {}", .{ferr});
                std.process.exit(@intFromEnum(ExitCode.usage));
            },
            error.InvalidInputFormat => {
                stderr_writer.writeAll(
                    "error: unknown input format; supported: csv, tsv, json, ndjson, xml\n",
                ) catch |werr| std.log.err("failed to write error message: {}", .{werr});
                stderr_writer.flush() catch |ferr| std.log.err("failed to flush: {}", .{ferr});
                std.process.exit(@intFromEnum(ExitCode.usage));
            },
            error.InvalidOutputFormat => {
                stderr_writer.writeAll(
                    "error: unknown output format; supported: csv, tsv, json, ndjson, xml\n",
                ) catch |werr| std.log.err("failed to write error message: {}", .{werr});
                stderr_writer.flush() catch |ferr| std.log.err("failed to flush: {}", .{ferr});
                std.process.exit(@intFromEnum(ExitCode.usage));
            },
            error.ColumnsWithQuery => {
                stderr_writer.writeAll("error: --columns cannot be combined with a query argument\n") catch |werr| {
                    std.log.err("failed to write error message: {}", .{werr});
                };
                stderr_writer.flush() catch |ferr| std.log.err("failed to flush: {}", .{ferr});
                std.process.exit(@intFromEnum(ExitCode.usage));
            },
            error.ValidateWithQuery => {
                stderr_writer.writeAll("error: --validate cannot be combined with a query argument\n") catch |werr| {
                    std.log.err("failed to write error message: {}", .{werr});
                };
                stderr_writer.flush() catch |ferr| std.log.err("failed to flush: {}", .{ferr});
                std.process.exit(@intFromEnum(ExitCode.usage));
            },
            error.InvalidOutputPath => {
                stderr_writer.writeAll("error: --output requires a non-empty file path\n") catch |werr| {
                    std.log.err("failed to write error message: {}", .{werr});
                };
                stderr_writer.flush() catch |ferr| std.log.err("failed to flush: {}", .{ferr});
                std.process.exit(@intFromEnum(ExitCode.usage));
            },
            error.OutputWithColumns => {
                stderr_writer.writeAll("error: --output cannot be combined with --columns\n") catch |werr| {
                    std.log.err("failed to write error message: {}", .{werr});
                };
                stderr_writer.flush() catch |ferr| std.log.err("failed to flush: {}", .{ferr});
                std.process.exit(@intFromEnum(ExitCode.usage));
            },
            error.OutputWithValidate => {
                stderr_writer.writeAll("error: --output cannot be combined with --validate\n") catch |werr| {
                    std.log.err("failed to write error message: {}", .{werr});
                };
                stderr_writer.flush() catch |ferr| std.log.err("failed to flush: {}", .{ferr});
                std.process.exit(@intFromEnum(ExitCode.usage));
            },
            error.ValidateWithColumns => {
                stderr_writer.writeAll("error: --validate cannot be combined with --columns\n") catch |werr| {
                    std.log.err("failed to write error message: {}", .{werr});
                };
                stderr_writer.flush() catch |ferr| std.log.err("failed to flush: {}", .{ferr});
                std.process.exit(@intFromEnum(ExitCode.usage));
            },
            error.SampleWithQuery => {
                stderr_writer.writeAll("error: --sample cannot be combined with a query argument\n") catch |werr| {
                    std.log.err("failed to write error message: {}", .{werr});
                };
                stderr_writer.flush() catch |ferr| std.log.err("failed to flush: {}", .{ferr});
                std.process.exit(@intFromEnum(ExitCode.usage));
            },
            error.SampleWithJson => {
                stderr_writer.writeAll("error: --sample cannot be combined with --json or a JSON output format\n") catch |werr| {
                    std.log.err("failed to write error message: {}", .{werr});
                };
                stderr_writer.flush() catch |ferr| std.log.err("failed to flush: {}", .{ferr});
                std.process.exit(@intFromEnum(ExitCode.usage));
            },
            error.SampleWithColumns => {
                stderr_writer.writeAll("error: --sample cannot be combined with --columns\n") catch |werr| {
                    std.log.err("failed to write error message: {}", .{werr});
                };
                stderr_writer.flush() catch |ferr| std.log.err("failed to flush: {}", .{ferr});
                std.process.exit(@intFromEnum(ExitCode.usage));
            },
            error.SampleWithValidate => {
                stderr_writer.writeAll("error: --sample cannot be combined with --validate\n") catch |werr| {
                    std.log.err("failed to write error message: {}", .{werr});
                };
                stderr_writer.flush() catch |ferr| std.log.err("failed to flush: {}", .{ferr});
                std.process.exit(@intFromEnum(ExitCode.usage));
            },
            error.SampleWithOutput => {
                stderr_writer.writeAll("error: --sample cannot be combined with --output\n") catch |werr| {
                    std.log.err("failed to write error message: {}", .{werr});
                };
                stderr_writer.flush() catch |ferr| std.log.err("failed to flush: {}", .{ferr});
                std.process.exit(@intFromEnum(ExitCode.usage));
            },
            error.InvalidSampleCount => {
                stderr_writer.writeAll("error: --sample requires a positive integer value\n") catch |werr| {
                    std.log.err("failed to write error message: {}", .{werr});
                };
                stderr_writer.flush() catch |ferr| std.log.err("failed to flush: {}", .{ferr});
                std.process.exit(@intFromEnum(ExitCode.usage));
            },
            error.MissingXmlFlagValue => {
                stderr_writer.writeAll(
                    "error: --xml-root and --xml-row require a value\n",
                ) catch |werr| std.log.err("failed to write error message: {}", .{werr});
                stderr_writer.flush() catch |ferr| std.log.err("failed to flush: {}", .{ferr});
                std.process.exit(@intFromEnum(ExitCode.usage));
            },
            error.InvalidXmlName => {
                stderr_writer.writeAll(
                    "error: --xml-root and --xml-row must be valid XML element names (letter/underscore first, then letters/digits/-/._/:)\n",
                ) catch |werr| std.log.err("failed to write error message: {}", .{werr});
                stderr_writer.flush() catch |ferr| std.log.err("failed to flush: {}", .{ferr});
                std.process.exit(@intFromEnum(ExitCode.usage));
            },
            else => {},
        }
        printUsage(stderr_writer) catch |werr| {
            std.log.err("failed to write usage: {}", .{werr});
        };
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
            runColumns(allocator, io.io(), col_args, stderr_writer, stdout_writer);
            stdout_file_writer.flush() catch |err| {
                std.log.err("failed to flush stdout: {}", .{err});
            };
            stderr_file_writer.flush() catch |err| {
                std.log.err("failed to flush stderr: {}", .{err});
            };
        },
        .validate => |val_args| {
            runValidate(allocator, io.io(), val_args, stderr_writer, stdout_writer);
            stdout_file_writer.flush() catch |err| {
                std.log.err("failed to flush stdout: {}", .{err});
            };
            stderr_file_writer.flush() catch |err| {
                std.log.err("failed to flush stderr: {}", .{err});
            };
        },
        .sample => |sample_args| {
            runSample(allocator, io.io(), sample_args, stderr_writer, stdout_writer);
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
