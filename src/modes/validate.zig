const std = @import("std");
const c = @import("c");
const csv_mod = @import("../csv.zig");
const json_mod = @import("../json.zig");
const xml_mod = @import("../xml.zig");
const yaml_mod = @import("../yaml.zig");
const build_options = @import("build_options");
const parquet_mod = @import("../parquet.zig");
const sqlite_mod = @import("../sqlite.zig");
const loader = @import("../loader.zig");
const args_mod = @import("../args.zig");

const ColumnType = sqlite_mod.ColumnType;
const inferTypes = loader.inferTypes;
const parseHeader = loader.parseHeader;
const fmtThousands = loader.fmtThousands;
const inference_buffer_size = loader.inference_buffer_size;

const ExitCode = args_mod.ExitCode;
const fatal = @import("../sqlite.zig").fatal;
const readAllInput = @import("../sqlite.zig").readAllInput;
const source = @import("source.zig");

pub fn runValidate(
    allocator: std.mem.Allocator,
    io: std.Io,
    parsed: args_mod.ParsedArgs,
    stderr_writer: *std.Io.Writer,
    stdout_writer: *std.Io.Writer,
) void {
    // Determine input source: file argument or stdin
    const input_source: union(enum) { file: []const u8, stdin } = if (parsed.files.len > 0)
        .{ .file = parsed.files[0].path }
    else
        .stdin;

    switch (parsed.input_format) {
        .csv, .tsv => {
            const col_delim: []const u8 = if (parsed.input_format == .tsv) "\t" else parsed.delimiter;
            var read_buf: [4096]u8 = undefined;
            const opened = source.openInput(io, input_source, stderr_writer);
            defer opened.deinit(io);
            var source_reader = std.Io.File.reader(opened.file, io, &read_buf);
            var csv_reader = csv_mod.csvReaderWithDelimiter(allocator, &source_reader.interface, col_delim);

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
            var mismatched_count: usize = 0;

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
                if (rec.len != num_cols) mismatched_count += 1;
                row_buffer.append(allocator, rec) catch
                    fatal("out of memory while buffering rows", stderr_writer, .csv_error, .{});
            }

            const types: []ColumnType = if (parsed.type_inference) blk: {
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
                if (record.len != num_cols) mismatched_count += 1;
            }

            if (mismatched_count > 0) {
                stderr_writer.print("warning: {d} rows have mismatched column counts (expected {d})\n", .{ mismatched_count, num_cols }) catch |err| {
                    std.log.err("failed to write warning: {}", .{err});
                };
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
                stdout_writer.print("{s} {s}", .{ col, t.displayName() }) catch |err| {
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
            var read_buf: [4096]u8 = undefined;
            const opened = source.openInput(io, input_source, stderr_writer);
            defer opened.deinit(io);
            var source_reader = std.Io.File.reader(opened.file, io, &read_buf);

            const input = readAllInput(allocator, &source_reader.interface, stderr_writer, "JSON input");
            defer allocator.free(input);
            if (input.len == 0) fatal("empty input", stderr_writer, .csv_error, .{});

            var json_parsed = std.json.parseFromSlice(std.json.Value, allocator, input, .{}) catch
                fatal("failed to parse JSON input", stderr_writer, .csv_error, .{});
            defer json_parsed.deinit();

            const fj = json_mod.firstJsonObject(json_parsed.value, parsed.json_path, stderr_writer);
            const first_obj = fj.first_obj orelse
                fatal("empty JSON array: cannot determine column names", stderr_writer, .csv_error, .{});
            const array = fj.array;

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
            var read_buf: [4096]u8 = undefined;
            const opened = source.openInput(io, input_source, stderr_writer);
            defer opened.deinit(io);
            var source_reader = std.Io.File.reader(opened.file, io, &read_buf);

            var line_num: usize = 0;
            var row_count: usize = 0;
            var cols_owned: ?[][]u8 = null;
            defer if (cols_owned) |cs| {
                for (cs) |col| allocator.free(col);
                allocator.free(cs);
            };

            while (true) {
                line_num += 1;
                const line = json_mod.readLine(allocator, &source_reader.interface) catch |err| switch (err) {
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
        .yaml => {
            var yaml_buf: [4096]u8 = undefined;
            const opened = source.openInput(io, input_source, stderr_writer);
            defer opened.deinit(io);
            var yaml_reader = std.Io.File.reader(opened.file, io, &yaml_buf);
            const yaml_db = sqlite_mod.openDb(false, null, stderr_writer);
            defer _ = c.sqlite3_close(yaml_db);
            const count = yaml_mod.loadYamlInput(allocator, &yaml_reader.interface, yaml_db, "t", null, stderr_writer);
            const cols = sqlite_mod.getTableColumns(allocator, yaml_db, "t", stderr_writer);
            defer {
                for (cols) |col| allocator.free(col);
                allocator.free(cols);
            }
            var count_buf: [32]u8 = undefined;
            const count_str = fmtThousands(&count_buf, count);
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
            var read_buf: [4096]u8 = undefined;
            const opened = source.openInput(io, input_source, stderr_writer);
            defer opened.deinit(io);
            var source_reader = std.Io.File.reader(opened.file, io, &read_buf);

            const summary = xml_mod.summarizeXml(allocator, &source_reader.interface, parsed.xml_root_input, parsed.xml_row_input, stderr_writer);
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
        .parquet => {
            var parquet_buf: [4096]u8 = undefined;
            const opened = source.openInput(io, input_source, stderr_writer);
            defer opened.deinit(io);
            var parquet_reader = std.Io.File.reader(opened.file, io, &parquet_buf);
            const parquet_db = sqlite_mod.openDb(false, null, stderr_writer);
            defer _ = c.sqlite3_close(parquet_db);
            const count = parquet_mod.loadParquetInput(allocator, io, parquet_db, "t", &parquet_reader.interface, null, stderr_writer);
            const cols = sqlite_mod.getTableColumns(allocator, parquet_db, "t", stderr_writer);
            defer {
                for (cols) |col| allocator.free(col);
                allocator.free(cols);
            }
            var count_buf: [32]u8 = undefined;
            const count_str = fmtThousands(&count_buf, count);
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
    }
}
