const std = @import("std");
const csv_mod = @import("../csv.zig");
const sqlite_mod = @import("../sqlite.zig");
const loader = @import("../loader.zig");
const args_mod = @import("../args.zig");
const format = @import("../format.zig");

const ColumnType = sqlite_mod.ColumnType;
const inferTypes = loader.inferTypes;
const parseHeader = loader.parseHeader;
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

pub fn runSample(
    allocator: std.mem.Allocator,
    io: std.Io,
    args: args_mod.SampleArgs,
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
