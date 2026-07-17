//! Parquet input loader powered by carquet (Copyright (c) 2025 Johan HG Natter, MIT License).
//! Acknowledgments: carquet library by Johan Natter.
//!
//! loadParquetInput
//!   Read all of `reader` as a Parquet file from a memory buffer, create table
//!   `table_name` in `db` with columns typed to match their physical + logical
//!   Parquet types, and insert every row. Supports all Parquet physical types
//!   via carquet with logical type mapping for DATE, TIMESTAMP, TIME, DECIMAL.

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

fn isLeapYear(year: i32) bool {
    return @rem(year, 4) == 0 and (@rem(year, 100) != 0 or @rem(year, 400) == 0);
}

// ponytail: Gregorian calendar only, no Julian/Gregorian switch. Non-negative epoch days only.
fn epochDaysToIso(days: i32, buf: *[10]u8) []const u8 {
    var y: i32 = 1970;
    var d = days;
    while (true) {
        const days_in_year: i32 = if (isLeapYear(y)) 366 else 365;
        if (d < days_in_year) break;
        d -= days_in_year;
        y += 1;
    }
    const month_days = [_]i32{ 31, if (isLeapYear(y)) @as(i32, 29) else @as(i32, 28), 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    var m: usize = 0;
    while (d >= month_days[m]) {
        d -= month_days[m];
        m += 1;
    }
    // Write YYYY-MM-DD manually to avoid FixedWriter alignment issues in dev Zig
    const yu = @as(u32, @intCast(y)); // non-negative; years >= 1970
    buf[0] = @as(u8, @intCast('0' + (yu / 1000) % 10));
    buf[1] = @as(u8, @intCast('0' + (yu / 100) % 10));
    buf[2] = @as(u8, @intCast('0' + (yu / 10) % 10));
    buf[3] = @as(u8, @intCast('0' + yu % 10));
    const mo: u32 = @intCast(m + 1);
    const da: u32 = @intCast(d + 1);
    buf[4] = '-';
    buf[5] = @as(u8, @intCast('0' + mo / 10));
    buf[6] = @as(u8, @intCast('0' + mo % 10));
    buf[7] = '-';
    buf[8] = @as(u8, @intCast('0' + da / 10));
    buf[9] = @as(u8, @intCast('0' + da % 10));
    return buf;
}

fn epochSecondsToIso(secs: i64, buf: *[20]u8) []const u8 {
    const days = @divTrunc(secs, 86400);
    const time_secs = @rem(secs, 86400);
    const hours = @divTrunc(time_secs, 3600);
    const minutes = @divTrunc(@rem(time_secs, 3600), 60);
    const seconds = @rem(time_secs, 60);
    var date_buf: [10]u8 = undefined;
    const date_str = epochDaysToIso(@intCast(days), &date_buf);
    @memcpy(buf[0..10], date_str);
    buf[10] = ' ';
    buf[11] = @as(u8, @intCast('0' + @as(u64, @intCast(hours)) / 10));
    buf[12] = @as(u8, @intCast('0' + @as(u64, @intCast(hours)) % 10));
    buf[13] = ':';
    buf[14] = @as(u8, @intCast('0' + @as(u64, @intCast(minutes)) / 10));
    buf[15] = @as(u8, @intCast('0' + @as(u64, @intCast(minutes)) % 10));
    buf[16] = ':';
    buf[17] = @as(u8, @intCast('0' + @as(u64, @intCast(seconds)) / 10));
    buf[18] = @as(u8, @intCast('0' + @as(u64, @intCast(seconds)) % 10));
    return buf[0..19];
}

fn millisOfDayToIso(millis: i32, buf: *[9]u8) []const u8 {
    const hours = @divTrunc(millis, 3600000);
    const remaining = @rem(millis, 3600000);
    const minutes = @divTrunc(remaining, 60000);
    const seconds = @divTrunc(@rem(remaining, 60000), 1000);
    buf[0] = @as(u8, @intCast('0' + @as(u64, @intCast(hours)) / 10));
    buf[1] = @as(u8, @intCast('0' + @as(u64, @intCast(hours)) % 10));
    buf[2] = ':';
    buf[3] = @as(u8, @intCast('0' + @as(u64, @intCast(minutes)) / 10));
    buf[4] = @as(u8, @intCast('0' + @as(u64, @intCast(minutes)) % 10));
    buf[5] = ':';
    buf[6] = @as(u8, @intCast('0' + @as(u64, @intCast(seconds)) / 10));
    buf[7] = @as(u8, @intCast('0' + @as(u64, @intCast(seconds)) % 10));
    return buf[0..8];
}

fn decimalToText(value: i64, scale: i32, buf: *[64]u8) []const u8 {
    if (scale == 0) {
        // ponytail: manual int-to-text avoids bufPrint FixedWriter issues
        return intToBuf(value, buf);
    }
    var pow10: i64 = 1;
    for (0..@as(usize, @intCast(scale))) |_| pow10 *= 10;
    const int_part = @divTrunc(value, pow10);
    const prefix = intToBuf(int_part, buf);
    buf[prefix.len] = '.';
    const dot_pos = prefix.len + 1;
    var f = @as(u64, @intCast(@abs(@rem(value, pow10))));
    var pos: usize = @intCast(scale);
    while (pos > 0) {
        pos -= 1;
        buf[dot_pos + pos] = @as(u8, @intCast('0' + (f % 10)));
        f /= 10;
    }
    return buf[0..dot_pos + @as(usize, @intCast(scale))];
}

fn intToBuf(value: i64, buf: []u8) []const u8 {
    if (value == 0) {
        buf[0] = '0';
        return buf[0..1];
    }
    var v = if (value < 0) @as(u64, @intCast(-value)) else @as(u64, @intCast(value));
    var pos: usize = 0;
    if (value < 0) {
        buf[0] = '-';
        pos = 1;
    }
    var end: usize = pos;
    while (v > 0) {
        buf[end] = @as(u8, @intCast('0' + (v % 10)));
        v /= 10;
        end += 1;
    }
    // Reverse digits
    var i = pos;
    var j = end - 1;
    while (i < j) {
        const tmp = buf[i];
        buf[i] = buf[j];
        buf[j] = tmp;
        i += 1;
        j -= 1;
    }
    return buf[0..end];
}

/// Map Parquet physical type to SQLite ColumnType (no logical type).
fn physToColType(phys: u8) sqlite_mod.ColumnType {
    return switch (phys) {
        carquet_c.CARQUET_PHYSICAL_BOOLEAN,
        carquet_c.CARQUET_PHYSICAL_INT32,
        carquet_c.CARQUET_PHYSICAL_INT64 => .INTEGER,
        carquet_c.CARQUET_PHYSICAL_FLOAT,
        carquet_c.CARQUET_PHYSICAL_DOUBLE => .REAL,
        carquet_c.CARQUET_PHYSICAL_BYTE_ARRAY,
        carquet_c.CARQUET_PHYSICAL_FIXED_LEN_BYTE_ARRAY,
        carquet_c.CARQUET_PHYSICAL_INT96 => .TEXT,
        else => unreachable,
    };
}

/// Read logical type id and param (scale for DECIMAL, time_unit for TIME/TIMESTAMP)
/// from a C pointer to carquet_logical_type_t by reading raw bytes
/// (the C struct contains a union, which isn't accessible through Zig's @cImport).
fn readLogicalType(logical: ?*const carquet_c.carquet_logical_type_t) struct { id: u8, param: i32 } {
    const ptr = logical orelse return .{ .id = 0, .param = 0 };
    const bytes = @as([*]const u8, @ptrCast(ptr));
    // id is a carquet_logical_type_id_t enum (4 bytes on this platform)
    const c_id = std.mem.readInt(u32, bytes[0..4], .little);
    const id: u8 = @truncate(c_id);
    if (id == carquet_c.CARQUET_LOGICAL_DECIMAL) {
        // struct layout: id(4) + precision(4) + scale(4) = offset 8
        const scale = std.mem.readInt(i32, bytes[8..12], .little);
        return .{ .id = id, .param = scale };
    }
    if (id == carquet_c.CARQUET_LOGICAL_TIME or id == carquet_c.CARQUET_LOGICAL_TIMESTAMP) {
        // struct layout: id(4) + time_unit(4) = offset 4
        const unit = std.mem.readInt(u32, bytes[4..8], .little);
        return .{ .id = id, .param = @as(i32, @intCast(unit)) };
    }
    return .{ .id = id, .param = 0 };
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
    const num_elements = carquet_c.carquet_schema_num_elements(schema);
    const num_cols = carquet_c.carquet_schema_num_columns(schema);
    const num_cols_usize = @as(usize, @intCast(num_cols));
    if (num_cols == 0)
        sqlite_mod.fatal("Parquet file has no columns", stderr_writer, .csv_error, .{});

    var col_names: std.ArrayList([]const u8) = .empty;
    var col_types: std.ArrayList(sqlite_mod.ColumnType) = .empty;
    var col_phys_types: std.ArrayList(u8) = .empty;
    var col_logical_ids: std.ArrayList(u8) = .empty;
    var col_logical_params: std.ArrayList(i32) = .empty;
    defer {
        for (col_names.items) |n| allocator.free(n);
        col_names.deinit(allocator);
        col_types.deinit(allocator);
        col_phys_types.deinit(allocator);
        col_logical_ids.deinit(allocator);
        col_logical_params.deinit(allocator);
    }

    // Walk schema tree (skip root at index 0). For flat schemas, leaf order
    // in tree-walk matches leaf-index order used by batch reader.
    for (1..@as(usize, @intCast(num_elements))) |elem_idx| {
        const node = carquet_c.carquet_schema_get_element(schema, @intCast(elem_idx));
        const name = std.mem.span(carquet_c.carquet_schema_node_name(node));

        if (!carquet_c.carquet_schema_node_is_leaf(node))
            sqlite_mod.fatal("nested Parquet types not supported (found group '{s}')", stderr_writer, .csv_error, .{name});

        const owned = allocator.dupe(u8, name) catch
            sqlite_mod.fatal("out of memory", stderr_writer, .csv_error, .{});
        col_names.append(allocator, owned) catch
            sqlite_mod.fatal("out of memory", stderr_writer, .csv_error, .{});

        const phys_type = carquet_c.carquet_schema_node_physical_type(node);
        const phys_u8 = @as(u8, @intCast(phys_type));
        const logical = carquet_c.carquet_schema_node_logical_type(node);

        const lt = readLogicalType(logical);
        const ctype: sqlite_mod.ColumnType = if (lt.id == carquet_c.CARQUET_LOGICAL_DATE and phys_u8 == carquet_c.CARQUET_PHYSICAL_INT32)
            .TEXT
        else if (lt.id == carquet_c.CARQUET_LOGICAL_TIME and (phys_u8 == carquet_c.CARQUET_PHYSICAL_INT32 or phys_u8 == carquet_c.CARQUET_PHYSICAL_INT64))
            .TEXT
        else if (lt.id == carquet_c.CARQUET_LOGICAL_TIMESTAMP and phys_u8 == carquet_c.CARQUET_PHYSICAL_INT64)
            .TEXT
        else if (lt.id == carquet_c.CARQUET_LOGICAL_DECIMAL and (phys_u8 == carquet_c.CARQUET_PHYSICAL_INT32 or phys_u8 == carquet_c.CARQUET_PHYSICAL_INT64))
            if (lt.param == 0) .INTEGER else .TEXT
        else
            physToColType(phys_u8);
        col_types.append(allocator, ctype) catch
            sqlite_mod.fatal("out of memory", stderr_writer, .csv_error, .{});
        col_phys_types.append(allocator, phys_u8) catch
            sqlite_mod.fatal("out of memory", stderr_writer, .csv_error, .{});
        col_logical_ids.append(allocator, lt.id) catch
            sqlite_mod.fatal("out of memory", stderr_writer, .csv_error, .{});
        col_logical_params.append(allocator, lt.param) catch
            sqlite_mod.fatal("out of memory", stderr_writer, .csv_error, .{});

        // Validate: num_columns must match leaf count from walk
        if (col_names.items.len > num_cols_usize)
            sqlite_mod.fatal("schema element count mismatch", stderr_writer, .csv_error, .{});
    }
    if (col_names.items.len != num_cols_usize)
        sqlite_mod.fatal("schema element count mismatch", stderr_writer, .csv_error, .{});

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
                const phys_type = col_phys_types.items[j];
                const logical_id = col_logical_ids.items[j];
                const logical_param = col_logical_params.items[j];

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

                // Logical type conversions (DATE, TIMESTAMP, TIME, DECIMAL)
                if (logical_id == carquet_c.CARQUET_LOGICAL_DATE) {
                    const arr: [*]const i32 = @ptrCast(@alignCast(data));
                    var buf_date: [10]u8 = undefined;
                    const iso = epochDaysToIso(arr[row_idx], &buf_date);
                    if (c.sqlite3_bind_text(stmt, param_idx, iso.ptr, @as(c_int, @intCast(iso.len)), sqlite_mod.sqliteTransient()) != c.SQLITE_OK)
                        sqlite_mod.fatalSqlWithContext(allocator, db, table_name, std.mem.span(c.sqlite3_errmsg(db)), stderr_writer);
                    continue;
                }

                if (logical_id == carquet_c.CARQUET_LOGICAL_TIMESTAMP) {
                    const arr: [*]const i64 = @ptrCast(@alignCast(data));
                    const unit: i32 = logical_param;
                    const divisor: i64 = switch (unit) {
                        carquet_c.CARQUET_TIME_UNIT_MILLIS => 1000,
                        carquet_c.CARQUET_TIME_UNIT_MICROS => 1_000_000,
                        carquet_c.CARQUET_TIME_UNIT_NANOS => 1_000_000_000,
                        else => 1000,
                    };
                    const secs = @divTrunc(arr[row_idx], divisor);
                    var buf_ts: [20]u8 = undefined;
                    const iso = epochSecondsToIso(secs, &buf_ts);
                    if (c.sqlite3_bind_text(stmt, param_idx, iso.ptr, @as(c_int, @intCast(iso.len)), sqlite_mod.sqliteTransient()) != c.SQLITE_OK)
                        sqlite_mod.fatalSqlWithContext(allocator, db, table_name, std.mem.span(c.sqlite3_errmsg(db)), stderr_writer);
                    continue;
                }

                if (logical_id == carquet_c.CARQUET_LOGICAL_TIME) {
                    const unit: i32 = logical_param;
                    const millis: i32 = if (phys_type == carquet_c.CARQUET_PHYSICAL_INT32) blk: {
                        const arr: [*]const i32 = @ptrCast(@alignCast(data));
                        break :blk arr[row_idx];
                    } else blk: {
                        const arr: [*]const i64 = @ptrCast(@alignCast(data));
                        const divisor: i64 = switch (unit) {
                            carquet_c.CARQUET_TIME_UNIT_MICROS => 1000,
                            carquet_c.CARQUET_TIME_UNIT_NANOS => 1_000_000,
                            else => 1,
                        };
                        break :blk @intCast(@divTrunc(arr[row_idx], divisor));
                    };
                    var buf_time: [9]u8 = undefined;
                    const iso = millisOfDayToIso(millis, &buf_time);
                    if (c.sqlite3_bind_text(stmt, param_idx, iso.ptr, @as(c_int, @intCast(iso.len)), sqlite_mod.sqliteTransient()) != c.SQLITE_OK)
                        sqlite_mod.fatalSqlWithContext(allocator, db, table_name, std.mem.span(c.sqlite3_errmsg(db)), stderr_writer);
                    continue;
                }

                if (logical_id == carquet_c.CARQUET_LOGICAL_DECIMAL) {
                    const scale = logical_param;
                    const raw: i64 = if (phys_type == carquet_c.CARQUET_PHYSICAL_INT32) blk: {
                        const arr: [*]const i32 = @ptrCast(@alignCast(data));
                        break :blk arr[row_idx];
                    } else blk: {
                        const arr: [*]const i64 = @ptrCast(@alignCast(data));
                        break :blk arr[row_idx];
                    };
                    if (scale == 0) {
                        if (c.sqlite3_bind_int64(stmt, param_idx, raw) != c.SQLITE_OK)
                            sqlite_mod.fatalSqlWithContext(allocator, db, table_name, std.mem.span(c.sqlite3_errmsg(db)), stderr_writer);
                    } else {
                        var buf_dec: [64]u8 = undefined;
                        const text = decimalToText(raw, scale, &buf_dec);
                        if (c.sqlite3_bind_text(stmt, param_idx, text.ptr, @as(c_int, @intCast(text.len)), sqlite_mod.sqliteTransient()) != c.SQLITE_OK)
                            sqlite_mod.fatalSqlWithContext(allocator, db, table_name, std.mem.span(c.sqlite3_errmsg(db)), stderr_writer);
                    }
                    continue;
                }

                // Fallback: physical-only binding (same as original)
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
                            if (ba.data == null or ba.length == 0) {
                                if (c.sqlite3_bind_text(stmt, param_idx, "", 0, sqlite_mod.sqlite_static) != c.SQLITE_OK)
                                    sqlite_mod.fatalSqlWithContext(allocator, db, table_name, std.mem.span(c.sqlite3_errmsg(db)), stderr_writer);
                            } else {
                                if (c.sqlite3_bind_text(stmt, param_idx, @as([*]const u8, @ptrCast(ba.data)), ba.length, sqlite_mod.sqlite_static) != c.SQLITE_OK)
                                    sqlite_mod.fatalSqlWithContext(allocator, db, table_name, std.mem.span(c.sqlite3_errmsg(db)), stderr_writer);
                            }
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
