const std = @import("std");
const csv_mod = @import("../csv.zig");
const json_mod = @import("../json.zig");
const xml_mod = @import("../xml.zig");
const sqlite_mod = @import("../sqlite.zig");
const loader = @import("../loader.zig");
const args_mod = @import("../args.zig");

const ColumnType = sqlite_mod.ColumnType;
const inferTypes = loader.inferTypes;
const parseHeader = loader.parseHeader;
const fmtThousands = loader.fmtThousands;
const inference_buffer_size = loader.inference_buffer_size;

const ExitCode = enum(u8) {
    success = 0,
    usage = 1,
    csv_error = 2,
    sql_error = 3,
};

fn fatal(comptime fmt: []const u8, writer: *std.Io.Writer, code: ExitCode, f_args: anytype) noreturn {
    writer.print("error: " ++ fmt ++ "\n", f_args) catch |err| {
        std.log.err("failed to write error message: {}", .{err});
    };
    writer.flush() catch |err| std.log.err("failed to flush: {}", .{err});
    std.process.exit(@intFromEnum(code));
}

pub fn runValidate(
    allocator: std.mem.Allocator,
    io: std.Io,
    args: args_mod.ValidateArgs,
    stderr_writer: *std.Io.Writer,
    stdout_writer: *std.Io.Writer,
) void {
    switch (args.input_format) {
        .csv, .tsv => {
            const col_delim: []const u8 = if (args.input_format == .tsv) "\t" else args.delimiter;
            var stdin_buf: [4096]u8 = undefined;
            var stdin_file_reader = std.Io.File.reader(std.Io.File.stdin(), io, &stdin_buf);
            var csv_reader = csv_mod.csvReaderWithDelimiter(allocator, &stdin_file_reader.interface, col_delim);

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
                const line = json_mod.readLine(allocator, &stdin_file_reader.interface) catch |err| switch (err) {
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

            const summary = xml_mod.summarizeXml(allocator, &stdin_file_reader.interface, args.xml_root_input, args.xml_row_input, stderr_writer);
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
