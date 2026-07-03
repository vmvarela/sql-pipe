const std = @import("std");
const csv_mod = @import("../csv.zig");
const json_mod = @import("../json.zig");
const xml_mod = @import("../xml.zig");
const loader = @import("../loader.zig");
const args_mod = @import("../args.zig");

const inferTypes = loader.inferTypes;
const parseHeader = loader.parseHeader;
const inference_buffer_size = loader.inference_buffer_size;

const ExitCode = args_mod.ExitCode;
const fatal = @import("../sqlite.zig").fatal;
const readAllInput = @import("../sqlite.zig").readAllInput;
const source = @import("source.zig");

pub fn runColumns(
    allocator: std.mem.Allocator,
    io: std.Io,
    args: args_mod.ColumnsArgs,
    stderr_writer: *std.Io.Writer,
    stdout_writer: *std.Io.Writer,
) void {
    // Determine input source: file argument or stdin
    const input_source: union(enum) { file: []const u8, stdin } = if (args.files.len > 0)
        .{ .file = args.files[0].path }
    else
        .stdin;

    switch (args.input_format) {
        .csv, .tsv => {
            const col_delim: []const u8 = if (args.input_format == .tsv) "\t" else args.delimiter;
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
                    stdout_writer.print("{s} {s}\n", .{ col, t.displayName() }) catch |err| {
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
            var read_buf: [4096]u8 = undefined;
            const opened = source.openInput(io, input_source, stderr_writer);
            defer opened.deinit(io);
            var source_reader = std.Io.File.reader(opened.file, io, &read_buf);

            const input = readAllInput(allocator, &source_reader.interface, stderr_writer, "JSON input");
            defer allocator.free(input);
            if (input.len == 0) fatal("empty input", stderr_writer, .csv_error, .{});

            var parsed = std.json.parseFromSlice(std.json.Value, allocator, input, .{}) catch
                fatal("failed to parse JSON input", stderr_writer, .csv_error, .{});
            defer parsed.deinit();

            const first_obj = json_mod.firstJsonObject(parsed.value, args.json_path, stderr_writer).first_obj orelse
                fatal("empty JSON array: cannot determine column names", stderr_writer, .csv_error, .{});

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
            var read_buf: [4096]u8 = undefined;
            const opened = source.openInput(io, input_source, stderr_writer);
            defer opened.deinit(io);
            var source_reader = std.Io.File.reader(opened.file, io, &read_buf);

            // Read until we find a non-empty line
            var line_num: usize = 0;
            while (true) {
                line_num += 1;
                const line = json_mod.readLine(allocator, &source_reader.interface) catch |err| switch (err) {
                    error.OutOfMemory => fatal("out of memory reading NDJSON", stderr_writer, .csv_error, .{}),
                    error.ReadFailed => fatal("line {d}: failed to read NDJSON", stderr_writer, .csv_error, .{line_num}),
                } orelse fatal("empty NDJSON input", stderr_writer, .csv_error, .{});
                defer allocator.free(line);

                const trimmed = std.mem.trim(u8, line, " \t\r");
                if (trimmed.len == 0) {
                    line_num -= 1;
                    continue;
                }

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
            var read_buf: [4096]u8 = undefined;
            const opened = source.openInput(io, input_source, stderr_writer);
            defer opened.deinit(io);
            var source_reader = std.Io.File.reader(opened.file, io, &read_buf);

            const names = xml_mod.getXmlColumnNames(allocator, &source_reader.interface, args.xml_root_input, args.xml_row_input, stderr_writer);
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
