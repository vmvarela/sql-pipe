const std = @import("std");
const c = @cImport({
    @cInclude("sqlite3.h");
});

// SQLITE_TRANSIENT: SQLite copies the value immediately, so the buffer can be reused.
const SQLITE_TRANSIENT: c.sqlite3_destructor_type = @ptrFromInt(std.math.maxInt(usize));

fn callback(data: ?*anyopaque, argc: c_int, argv: [*c][*c]u8, col_names: [*c][*c]u8) callconv(.c) c_int {
    _ = data;
    _ = col_names;
    const stdout = std.fs.File.stdout();
    var i: usize = 0;
    while (i < @as(usize, @intCast(argc))) : (i += 1) {
        if (i > 0) stdout.writeAll(",") catch return 1;
        const val = if (argv[i] != null) std.mem.span(argv[i]) else "NULL";
        stdout.writeAll(val) catch return 1;
    }
    stdout.writeAll("\n") catch return 1;
    return 0;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // 1. Parse CLI arguments
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        std.debug.print("Usage: sql-pipe <query>\n", .{});
        std.debug.print("Example: echo 'name,age\\nAlice,30' | sql-pipe 'SELECT * FROM t'\n", .{});
        std.process.exit(1);
    }

    const query = args[1];

    // 2. Open in-memory SQLite database
    var db: ?*c.sqlite3 = null;
    if (c.sqlite3_open(":memory:", &db) != c.SQLITE_OK) {
        std.debug.print("Failed to open in-memory database\n", .{});
        std.process.exit(1);
    }
    defer _ = c.sqlite3_close(db);

    const stdin = std.fs.File.stdin().deprecatedReader();

    // 3. Read header line and generate schema
    const header_line = try stdin.readUntilDelimiterOrEofAlloc(allocator, '\n', 1024 * 1024) orelse {
        std.debug.print("Error: empty input\n", .{});
        std.process.exit(1);
    };
    defer allocator.free(header_line);

    // Trim trailing \r (Windows line endings)
    const headers_str = if (header_line.len > 0 and header_line[header_line.len - 1] == '\r')
        header_line[0 .. header_line.len - 1]
    else
        header_line;

    // Parse column names
    var cols: std.ArrayList([]const u8) = .{};
    defer cols.deinit(allocator);
    {
        var it = std.mem.splitScalar(u8, headers_str, ',');
        var valid_col_count: usize = 0;
        while (it.next()) |col_raw| {
            const col = std.mem.trim(u8, col_raw, " \t\r");
            if (col.len == 0) {
                std.debug.print("Error: empty column name in header\n", .{});
                std.process.exit(1);
            }
            try cols.append(allocator, col);
            valid_col_count += 1;
        }
        if (valid_col_count == 0) {
            std.debug.print("Error: no valid column names in header\n", .{});
            std.process.exit(1);
        }
    }
    const num_cols = cols.items.len;

    // Build and execute CREATE TABLE statement
    {
        var sql: std.ArrayList(u8) = .{};
        defer sql.deinit(allocator);
        try sql.appendSlice(allocator, "CREATE TABLE t (");
        for (cols.items, 0..) |col, i| {
            if (i > 0) try sql.appendSlice(allocator, ", ");
            try sql.appendSlice(allocator, col);
            try sql.appendSlice(allocator, " TEXT");
        }
        try sql.appendSlice(allocator, ")");
        try sql.append(allocator, 0);

        var errmsg: [*c]u8 = null;
        if (c.sqlite3_exec(db, sql.items.ptr, null, null, &errmsg) != c.SQLITE_OK) {
            std.debug.print("CREATE TABLE failed: {s}\n", .{std.mem.span(errmsg)});
            c.sqlite3_free(errmsg);
            std.process.exit(1);
        }
    }

    // 4. Begin transaction for batched inserts
    {
        var errmsg: [*c]u8 = null;
        const rc = c.sqlite3_exec(db, "BEGIN TRANSACTION", null, null, &errmsg);
        if (rc != c.SQLITE_OK) {
            if (errmsg != null) {
                std.debug.print("BEGIN TRANSACTION failed: {s}\n", .{std.mem.span(errmsg)});
                c.sqlite3_free(errmsg);
            } else {
                std.debug.print("BEGIN TRANSACTION failed with code {d}\n", .{rc});
            }
            // Attempt to rollback any partial transaction state
            var rb_errmsg: [*c]u8 = null;
            _ = c.sqlite3_exec(db, "ROLLBACK", null, null, &rb_errmsg);
            if (rb_errmsg != null) {
                c.sqlite3_free(rb_errmsg);
            }
            std.process.exit(1);
        }
    }

    // Prepare INSERT statement once
    var insert_sql: std.ArrayList(u8) = .{};
    defer insert_sql.deinit(allocator);
    try insert_sql.appendSlice(allocator, "INSERT INTO t VALUES (");
    for (0..num_cols) |i| {
        if (i > 0) try insert_sql.append(allocator, ',');
        try insert_sql.append(allocator, '?');
    }
    try insert_sql.appendSlice(allocator, ")");
    try insert_sql.append(allocator, 0);

    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(db, insert_sql.items.ptr, -1, &stmt, null) != c.SQLITE_OK) {
        std.debug.print("Failed to prepare INSERT statement\n", .{});
        std.process.exit(1);
    }
    defer _ = c.sqlite3_finalize(stmt);

    // 5. Read and insert data rows
    while (true) {
        const line = try stdin.readUntilDelimiterOrEofAlloc(allocator, '\n', 1024 * 1024) orelse break;
        defer allocator.free(line);

        const row = if (line.len > 0 and line[line.len - 1] == '\r')
            line[0 .. line.len - 1]
        else
            line;
        if (row.len == 0) continue;

        _ = c.sqlite3_reset(stmt);
        var col_idx: c_int = 1;
        var it = std.mem.splitScalar(u8, row, ',');
        while (it.next()) |val| : (col_idx += 1) {
            _ = c.sqlite3_bind_text(stmt, col_idx, val.ptr, @intCast(val.len), SQLITE_TRANSIENT);
        }
        _ = c.sqlite3_step(stmt);
    }

    // Commit transaction
    {
        var errmsg: [*c]u8 = null;
        _ = c.sqlite3_exec(db, "COMMIT", null, null, &errmsg);
    }

    // 6. Execute user query and print results
    const query_z = try allocator.dupeZ(u8, query);
    defer allocator.free(query_z);

    var errmsg: [*c]u8 = null;
    if (c.sqlite3_exec(db, query_z, callback, null, &errmsg) != c.SQLITE_OK) {
        std.debug.print("Query error: {s}\n", .{std.mem.span(errmsg)});
        c.sqlite3_free(errmsg);
        std.process.exit(1);
    }
}


