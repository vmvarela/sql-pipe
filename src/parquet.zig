//! Parquet input loader powered by carquet (Copyright (c) 2025 Johan HG Natter, MIT License).
//! Acknowledgments: carquet library by Johan Natter.
//!
//! loadParquetInput
//!   Read all of `reader` as a Parquet file from a memory buffer, create table
//!   `table_name` in `db` with columns typed to match their physical Parquet
//!   type, and insert every row. Supports all Parquet physical types via carquet.
//!
//! ponytail: logical types (DECIMAL scale, TIMESTAMP→ISO, DATE→ISO) not yet
//! mapped; physical-only for v1. Upgrade: inspect carquet_schema_column_logical_type().

const std = @import("std");
const c = @import("c");

const sqlite_mod = @import("sqlite.zig");

const carquet_c = @cImport({
    @cInclude("carquet/carquet.h");
});

fn isNull(bitmap: ?*const u8, row_idx: usize) bool {
    const b = bitmap orelse return false;
    const byte = @as([*]const u8, @ptrCast(@alignCast(b)))[row_idx / 8];
    return (byte & (@as(u8, 1) << @intCast(row_idx % 8))) == 0;
}

pub fn loadParquetInput(
    allocator: std.mem.Allocator,
    io: std.Io,
    db: *c.sqlite3,
    table_name: []const u8,
    reader: *std.Io.Reader,
    max_rows: ?usize,
    stderr_writer: *std.Io.Writer,
) usize {
    _ = io;

    const buf = sqlite_mod.readAllInput(allocator, reader, stderr_writer, "Parquet input");
    defer allocator.free(buf);
    if (buf.len == 0) return 0;

    if (buf.len < 4 or !std.mem.eql(u8, buf[0..4], "PAR1"))
        sqlite_mod.fatal("not a valid Parquet file (missing PAR1 header)", stderr_writer, .csv_error, .{});

    var err: carquet_c.carquet_error_t = .{ .code = carquet_c.CARQUET_OK };
    const reader_ptr = carquet_c.carquet_reader_open_buffer(buf.ptr, buf.len, null, &err) orelse
        sqlite_mod.fatal("carquet: failed to open reader: {s}", stderr_writer, .csv_error, .{std.mem.sliceTo(&err.message, 0)});
    defer carquet_c.carquet_reader_close(reader_ptr);

    const schema = carquet_c.carquet_reader_schema(reader_ptr);
    const num_cols = carquet_c.carquet_schema_num_columns(schema);
    const num_cols_usize = @as(usize, @intCast(num_cols));
    if (num_cols == 0)
        sqlite_mod.fatal("Parquet file has no columns", stderr_writer, .csv_error, .{});

    var col_names: std.ArrayList([]const u8) = .empty;
    var col_types: std.ArrayList(sqlite_mod.ColumnType) = .empty;
    defer {
        for (col_names.items) |n| allocator.free(n);
        col_names.deinit(allocator);
        col_types.deinit(allocator);
    }

    for (0..num_cols_usize) |i| {
        const idx: i32 = @intCast(i);
        const name = std.mem.span(carquet_c.carquet_schema_column_name(schema, idx));
        const owned = allocator.dupe(u8, name) catch
            sqlite_mod.fatal("out of memory", stderr_writer, .csv_error, .{});
        col_names.append(allocator, owned) catch
            sqlite_mod.fatal("out of memory", stderr_writer, .csv_error, .{});

        const phys_type = carquet_c.carquet_schema_column_type(schema, idx);
        const ctype: sqlite_mod.ColumnType = switch (phys_type) {
            carquet_c.CARQUET_PHYSICAL_BOOLEAN,
            carquet_c.CARQUET_PHYSICAL_INT32,
            carquet_c.CARQUET_PHYSICAL_INT64 => .INTEGER,
            carquet_c.CARQUET_PHYSICAL_FLOAT,
            carquet_c.CARQUET_PHYSICAL_DOUBLE => .REAL,
            carquet_c.CARQUET_PHYSICAL_BYTE_ARRAY,
            carquet_c.CARQUET_PHYSICAL_FIXED_LEN_BYTE_ARRAY,
            carquet_c.CARQUET_PHYSICAL_INT96 => .TEXT,
            else => sqlite_mod.fatal("carquet: unsupported physical type at column '{s}'", stderr_writer, .csv_error, .{name}),
        };
        col_types.append(allocator, ctype) catch
            sqlite_mod.fatal("out of memory", stderr_writer, .csv_error, .{});
    }

    sqlite_mod.createTable(allocator, db, table_name, col_names.items, col_types.items, stderr_writer);
    sqlite_mod.beginTransaction(db, stderr_writer);

    const stmt = sqlite_mod.prepareInsertStmt(allocator, db, table_name, num_cols_usize, stderr_writer);
    defer _ = c.sqlite3_finalize(stmt);

    var batch_config: carquet_c.carquet_batch_reader_config_t = undefined;
    carquet_c.carquet_batch_reader_config_init(&batch_config);
    batch_config.batch_size = 10000;

    var batch_err: carquet_c.carquet_error_t = .{ .code = carquet_c.CARQUET_OK };
    const batch_reader = carquet_c.carquet_batch_reader_create(reader_ptr, &batch_config, &batch_err) orelse
        sqlite_mod.fatal("carquet: failed to create batch reader: {s}", stderr_writer, .csv_error, .{std.mem.sliceTo(&batch_err.message, 0)});
    defer carquet_c.carquet_batch_reader_free(batch_reader);

    var rows_inserted: usize = 0;
    var batch: ?*carquet_c.carquet_row_batch_t = null;

    while (carquet_c.carquet_batch_reader_next(batch_reader, &batch) == carquet_c.CARQUET_OK and batch != null) {
        defer carquet_c.carquet_row_batch_free(batch);

        var first_count: i64 = 0;
        var dummy_data: ?*const anyopaque = undefined;
        var dummy_null: ?*const u8 = undefined;
        _ = carquet_c.carquet_row_batch_column(batch, 0, &dummy_data, &dummy_null, &first_count);
        const num_rows = @as(usize, @intCast(first_count));
        if (num_rows == 0) continue;

        const col_data = allocator.alloc(?*const anyopaque, num_cols_usize) catch
            sqlite_mod.fatal("out of memory", stderr_writer, .csv_error, .{});
        defer allocator.free(col_data);
        const col_bitmap = allocator.alloc(?*const u8, num_cols_usize) catch
            sqlite_mod.fatal("out of memory", stderr_writer, .csv_error, .{});
        defer allocator.free(col_bitmap);
        const col_counts = allocator.alloc(i64, num_cols_usize) catch
            sqlite_mod.fatal("out of memory", stderr_writer, .csv_error, .{});
        defer allocator.free(col_counts);

        for (0..num_cols_usize) |j| {
            const col_idx: i32 = @intCast(j);
            var data: ?*const anyopaque = undefined;
            var null_bitmap: ?*const u8 = undefined;
            var count: i64 = undefined;
            _ = carquet_c.carquet_row_batch_column(batch, col_idx, &data, &null_bitmap, &count);
            col_data[j] = data;
            col_bitmap[j] = null_bitmap;
            col_counts[j] = count;
        }

        for (0..num_rows) |row_idx| {
            rows_inserted += 1;
            sqlite_mod.checkMaxRows(rows_inserted, max_rows, stderr_writer);

            _ = c.sqlite3_reset(stmt);
            _ = c.sqlite3_clear_bindings(stmt);

            for (0..num_cols_usize) |j| {
                const param_idx: c_int = @intCast(j + 1);
                const phys_type = carquet_c.carquet_schema_column_type(schema, @intCast(j));

                if (row_idx >= @as(usize, @intCast(col_counts[j]))) {
                    if (c.sqlite3_bind_null(stmt, param_idx) != c.SQLITE_OK)
                        sqlite_mod.fatalSqlWithContext(allocator, db, table_name, std.mem.span(c.sqlite3_errmsg(db)), stderr_writer);
                    continue;
                }

                if (isNull(col_bitmap[j], row_idx)) {
                    if (c.sqlite3_bind_null(stmt, param_idx) != c.SQLITE_OK)
                        sqlite_mod.fatalSqlWithContext(allocator, db, table_name, std.mem.span(c.sqlite3_errmsg(db)), stderr_writer);
                    continue;
                }

                const data = col_data[j].?;
                switch (phys_type) {
                    carquet_c.CARQUET_PHYSICAL_BOOLEAN => {
                        const arr: [*]const u8 = @ptrCast(@alignCast(data));
                        if (c.sqlite3_bind_int64(stmt, param_idx, arr[row_idx]) != c.SQLITE_OK)
                            sqlite_mod.fatalSqlWithContext(allocator, db, table_name, std.mem.span(c.sqlite3_errmsg(db)), stderr_writer);
                    },
                    carquet_c.CARQUET_PHYSICAL_INT32 => {
                        const arr: [*]const i32 = @ptrCast(@alignCast(data));
                        if (c.sqlite3_bind_int64(stmt, param_idx, arr[row_idx]) != c.SQLITE_OK)
                            sqlite_mod.fatalSqlWithContext(allocator, db, table_name, std.mem.span(c.sqlite3_errmsg(db)), stderr_writer);
                    },
                    carquet_c.CARQUET_PHYSICAL_INT64 => {
                        const arr: [*]const i64 = @ptrCast(@alignCast(data));
                        if (c.sqlite3_bind_int64(stmt, param_idx, arr[row_idx]) != c.SQLITE_OK)
                            sqlite_mod.fatalSqlWithContext(allocator, db, table_name, std.mem.span(c.sqlite3_errmsg(db)), stderr_writer);
                    },
                    carquet_c.CARQUET_PHYSICAL_FLOAT => {
                        const arr: [*]const f32 = @ptrCast(@alignCast(data));
                        if (c.sqlite3_bind_double(stmt, param_idx, arr[row_idx]) != c.SQLITE_OK)
                            sqlite_mod.fatalSqlWithContext(allocator, db, table_name, std.mem.span(c.sqlite3_errmsg(db)), stderr_writer);
                    },
                    carquet_c.CARQUET_PHYSICAL_DOUBLE => {
                        const arr: [*]const f64 = @ptrCast(@alignCast(data));
                        if (c.sqlite3_bind_double(stmt, param_idx, arr[row_idx]) != c.SQLITE_OK)
                            sqlite_mod.fatalSqlWithContext(allocator, db, table_name, std.mem.span(c.sqlite3_errmsg(db)), stderr_writer);
                    },
                    carquet_c.CARQUET_PHYSICAL_BYTE_ARRAY,
                    carquet_c.CARQUET_PHYSICAL_FIXED_LEN_BYTE_ARRAY,
                    carquet_c.CARQUET_PHYSICAL_INT96 => {
                        const arr: [*]const carquet_c.carquet_byte_array_t = @ptrCast(@alignCast(data));
                        const ba = arr[row_idx];
                        if (c.sqlite3_bind_text(stmt, param_idx, @as([*]const u8, @ptrCast(ba.data)), ba.length, sqlite_mod.sqlite_static) != c.SQLITE_OK)
                            sqlite_mod.fatalSqlWithContext(allocator, db, table_name, std.mem.span(c.sqlite3_errmsg(db)), stderr_writer);
                    },
                    else => unreachable,
                }
            }

            if (c.sqlite3_step(stmt) != c.SQLITE_DONE)
                sqlite_mod.fatalSqlWithContext(allocator, db, table_name, std.mem.span(c.sqlite3_errmsg(db)), stderr_writer);
        }
    }

    sqlite_mod.commitTransaction(db, stderr_writer);
    return rows_inserted;
}
