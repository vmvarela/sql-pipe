//! Parquet input loader powered by zig-parquet (DynamicReader API).
//!
//! loadParquetInput
//!   Read all of `reader` as a Parquet file from a memory buffer, create table
//!   `table_name` in `db` with columns typed to match their physical + logical
//!   Parquet types, and insert every row. Supports all Parquet physical types
//!   via zig-parquet with logical type mapping for DATE, TIMESTAMP, TIME, DECIMAL.

const std = @import("std");
const c = @import("c");

const sqlite_mod = @import("sqlite.zig");
const parquet = @import("zig_parquet");

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

/// Map a Parquet physical type to a SQLite ColumnType (no logical type mapping).
fn physicalToAffinity(phys: parquet.format.PhysicalType) sqlite_mod.ColumnType {
    return switch (phys) {
        .boolean, .int32, .int64 => .INTEGER,
        .int96 => .TEXT, // bound as ISO timestamp text
        .float, .double => .REAL,
        .byte_array, .fixed_len_byte_array => .TEXT,
    };
}

/// Map a leaf column's schema (logical type preferred, physical fallback) to SQLite ColumnType.
fn columnToSqliteType(reader: *parquet.DynamicReader, col_idx: usize) sqlite_mod.ColumnType {
    const elem = reader.getLeafSchemaElement(col_idx) orelse unreachable;
    const logical = reader.getColumnLogicalType(col_idx);

    // Logical types take precedence for columns that carry a semantic meaning.
    if (logical) |lt| {
        return switch (lt) {
            .date => .TEXT, // epochDaysToIso
            .time => .TEXT, // millisOfDayToIso
            .timestamp => .TEXT, // epochSecondsToIso
            .decimal => |d| if (d.scale == 0) .INTEGER else .TEXT, // decimalToText
            else => physicalToAffinity(elem.type_.?),
        };
    }
    return physicalToAffinity(elem.type_.?);
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

    // ponytail: openBufferDynamic reads straight from the in-memory buffer, avoiding
    // a temp file round-trip. `buf` outlives the reader (both freed at function exit).
    var dyn = parquet.openBufferDynamic(allocator, buf, .{}) catch |err|
        sqlite_mod.fatal("parquet: failed to open reader: {s}", stderr_writer, .csv_error, .{@errorName(err)});
    defer dyn.deinit();

    // Reject nested types (groups) — flat schemas only, same as before.
    const schema = dyn.getSchema();
    for (1..schema.len) |i| {
        const el = schema[i];
        if (el.num_children != null)
            sqlite_mod.fatal("nested Parquet types not supported (found group '{s}')", stderr_writer, .csv_error, .{el.name});
    }

    const num_cols = dyn.getNumColumns();
    const num_cols_usize: usize = num_cols;
    if (num_cols_usize == 0)
        sqlite_mod.fatal("Parquet file has no columns", stderr_writer, .csv_error, .{});

    var col_names: std.ArrayList([]const u8) = .empty;
    var col_types: std.ArrayList(sqlite_mod.ColumnType) = .empty;
    defer {
        for (col_names.items) |n| allocator.free(n);
        col_names.deinit(allocator);
        col_types.deinit(allocator);
    }

    for (0..num_cols_usize) |col_idx| {
        const elem = dyn.getLeafSchemaElement(col_idx) orelse unreachable;

        const owned = allocator.dupe(u8, elem.name) catch
            sqlite_mod.fatal("out of memory", stderr_writer, .csv_error, .{});
        col_names.append(allocator, owned) catch
            sqlite_mod.fatal("out of memory", stderr_writer, .csv_error, .{});

        const ctype = columnToSqliteType(&dyn, col_idx);
        col_types.append(allocator, ctype) catch
            sqlite_mod.fatal("out of memory", stderr_writer, .csv_error, .{});
    }

    // Precompute per-column metadata once, avoiding a linear schema scan
    // (getLeafSchemaElement / getColumnLogicalType) for every row x column.
    const col_phys_types = allocator.alloc(parquet.format.PhysicalType, num_cols_usize) catch
        sqlite_mod.fatal("out of memory", stderr_writer, .csv_error, .{});
    defer allocator.free(col_phys_types);
    const col_logical_types = allocator.alloc(?parquet.format.LogicalType, num_cols_usize) catch
        sqlite_mod.fatal("out of memory", stderr_writer, .csv_error, .{});
    defer allocator.free(col_logical_types);
    for (0..num_cols_usize) |col_idx| {
        const elem = dyn.getLeafSchemaElement(col_idx) orelse unreachable;
        col_phys_types[col_idx] = elem.type_.?;
        col_logical_types[col_idx] = dyn.getColumnLogicalType(col_idx);
    }

    sqlite_mod.createTable(allocator, db, table_name, col_names.items, col_types.items, stderr_writer);
    sqlite_mod.beginTransaction(db, stderr_writer);

    const stmt = sqlite_mod.prepareInsertStmt(allocator, db, table_name, num_cols_usize, stderr_writer);
    defer _ = c.sqlite3_finalize(stmt);

    var rows_inserted: usize = 0;
    const num_rgs = dyn.getNumRowGroups();

    for (0..num_rgs) |rg_idx| {
        const rows = dyn.readAllRows(rg_idx) catch |err|
            sqlite_mod.fatal("parquet: failed to read row group: {s}", stderr_writer, .csv_error, .{@errorName(err)});
        defer {
            for (rows) |row| row.deinit();
            allocator.free(rows);
        }

        for (rows) |row| {
            rows_inserted += 1;
            sqlite_mod.checkMaxRows(rows_inserted, max_rows, stderr_writer);

            _ = c.sqlite3_reset(stmt);
            _ = c.sqlite3_clear_bindings(stmt);

            for (0..num_cols_usize) |col_idx| {
                const param_idx: c_int = @intCast(col_idx + 1);
                const val = row.values[col_idx];
                const phys = col_phys_types[col_idx];

                if (val.isNull()) {
                    if (c.sqlite3_bind_null(stmt, param_idx) != c.SQLITE_OK)
                        sqlite_mod.fatalSqlWithContext(allocator, db, table_name, std.mem.span(c.sqlite3_errmsg(db)), stderr_writer);
                    continue;
                }

                const logical = col_logical_types[col_idx];
                var handled = false;

                // Logical-type conversions (DATE, TIMESTAMP, TIME, DECIMAL).
                // Other logical types (string, json, uuid, int, ...) fall through
                // to physical-type binding below.
                if (logical) |lt| {
                    switch (lt) {
                    .date => {
                        const days = val.asInt32().?;
                        var b: [10]u8 = undefined;
                        const iso = epochDaysToIso(days, &b);
                        if (c.sqlite3_bind_text(stmt, param_idx, iso.ptr, @intCast(iso.len), sqlite_mod.sqliteTransient()) != c.SQLITE_OK)
                            sqlite_mod.fatalSqlWithContext(allocator, db, table_name, std.mem.span(c.sqlite3_errmsg(db)), stderr_writer);
                        handled = true;
                    },
                    .time => |t| {
                        const millis: i32 = if (phys == .int32) val.asInt32().? else blk: {
                            const raw = val.asInt64().?;
                            const divisor: i64 = switch (t.unit) {
                                .millis => 1,
                                .micros => 1000,
                                .nanos => 1_000_000,
                            };
                            break :blk @intCast(@divTrunc(raw, divisor));
                        };
                        var b: [9]u8 = undefined;
                        const iso = millisOfDayToIso(millis, &b);
                        if (c.sqlite3_bind_text(stmt, param_idx, iso.ptr, @intCast(iso.len), sqlite_mod.sqliteTransient()) != c.SQLITE_OK)
                            sqlite_mod.fatalSqlWithContext(allocator, db, table_name, std.mem.span(c.sqlite3_errmsg(db)), stderr_writer);
                        handled = true;
                    },
                    .timestamp => |t| {
                        const divisor: i64 = switch (t.unit) {
                            .millis => 1000,
                            .micros => 1_000_000,
                            .nanos => 1_000_000_000,
                        };
                        const secs = @divTrunc(val.asInt64().?, divisor);
                        var b: [20]u8 = undefined;
                        const iso = epochSecondsToIso(secs, &b);
                        if (c.sqlite3_bind_text(stmt, param_idx, iso.ptr, @intCast(iso.len), sqlite_mod.sqliteTransient()) != c.SQLITE_OK)
                            sqlite_mod.fatalSqlWithContext(allocator, db, table_name, std.mem.span(c.sqlite3_errmsg(db)), stderr_writer);
                        handled = true;
                    },
                    .decimal => |d| {
                        if (phys == .byte_array or phys == .fixed_len_byte_array) {
                            const bytes = val.asBytes().?;
                            if (c.sqlite3_bind_text(stmt, param_idx, bytes.ptr, @intCast(bytes.len), sqlite_mod.sqlite_static) != c.SQLITE_OK)
                                sqlite_mod.fatalSqlWithContext(allocator, db, table_name, std.mem.span(c.sqlite3_errmsg(db)), stderr_writer);
                        } else {
                        const raw: i64 = if (phys == .int32) @as(i64, @intCast(val.asInt32().?)) else val.asInt64().?;
                        if (d.scale == 0) {
                            if (c.sqlite3_bind_int64(stmt, param_idx, raw) != c.SQLITE_OK)
                                sqlite_mod.fatalSqlWithContext(allocator, db, table_name, std.mem.span(c.sqlite3_errmsg(db)), stderr_writer);
                        } else {
                            var b: [64]u8 = undefined;
                            const text = decimalToText(raw, d.scale, &b);
                            if (c.sqlite3_bind_text(stmt, param_idx, text.ptr, @intCast(text.len), sqlite_mod.sqliteTransient()) != c.SQLITE_OK)
                                sqlite_mod.fatalSqlWithContext(allocator, db, table_name, std.mem.span(c.sqlite3_errmsg(db)), stderr_writer);
                        }
                        }
                        handled = true;
                    },
                    else => {},
                    }
                }
                if (handled) continue;

                // Physical-only binding.
                switch (phys) {
                    .boolean => {
                        if (c.sqlite3_bind_int64(stmt, param_idx, @as(i64, @intFromBool(val.asBool().?))) != c.SQLITE_OK)
                            sqlite_mod.fatalSqlWithContext(allocator, db, table_name, std.mem.span(c.sqlite3_errmsg(db)), stderr_writer);
                    },
                    .int32 => {
                        if (c.sqlite3_bind_int64(stmt, param_idx, @as(i64, @intCast(val.asInt32().?))) != c.SQLITE_OK)
                            sqlite_mod.fatalSqlWithContext(allocator, db, table_name, std.mem.span(c.sqlite3_errmsg(db)), stderr_writer);
                    },
                    .int64 => {
                        if (c.sqlite3_bind_int64(stmt, param_idx, val.asInt64().?) != c.SQLITE_OK)
                            sqlite_mod.fatalSqlWithContext(allocator, db, table_name, std.mem.span(c.sqlite3_errmsg(db)), stderr_writer);
                    },
                    .int96 => {
                        const nanos = val.asInt64().?;
                        const secs = @divTrunc(nanos, 1_000_000_000);
                        var b: [20]u8 = undefined;
                        const iso = epochSecondsToIso(secs, &b);
                        if (c.sqlite3_bind_text(stmt, param_idx, iso.ptr, @intCast(iso.len), sqlite_mod.sqliteTransient()) != c.SQLITE_OK)
                            sqlite_mod.fatalSqlWithContext(allocator, db, table_name, std.mem.span(c.sqlite3_errmsg(db)), stderr_writer);
                    },
                    .float => {
                        if (c.sqlite3_bind_double(stmt, param_idx, @as(f64, @floatCast(val.asFloat().?))) != c.SQLITE_OK)
                            sqlite_mod.fatalSqlWithContext(allocator, db, table_name, std.mem.span(c.sqlite3_errmsg(db)), stderr_writer);
                    },
                    .double => {
                        if (c.sqlite3_bind_double(stmt, param_idx, val.asDouble().?) != c.SQLITE_OK)
                            sqlite_mod.fatalSqlWithContext(allocator, db, table_name, std.mem.span(c.sqlite3_errmsg(db)), stderr_writer);
                    },
                    .byte_array, .fixed_len_byte_array => {
                        const bytes = val.asBytes().?;
                        if (c.sqlite3_bind_text(stmt, param_idx, bytes.ptr, @intCast(bytes.len), sqlite_mod.sqlite_static) != c.SQLITE_OK)
                            sqlite_mod.fatalSqlWithContext(allocator, db, table_name, std.mem.span(c.sqlite3_errmsg(db)), stderr_writer);
                    },
                }
            }

            if (c.sqlite3_step(stmt) != c.SQLITE_DONE)
                sqlite_mod.fatalSqlWithContext(allocator, db, table_name, std.mem.span(c.sqlite3_errmsg(db)), stderr_writer);
        }
    }

    sqlite_mod.commitTransaction(db, stderr_writer);
    return rows_inserted;
}
