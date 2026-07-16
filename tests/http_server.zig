const std = @import("std");

pub fn main(init: std.process.Init.Minimal) !void {
    var io_threaded = std.Io.Threaded.init_single_threaded;
    const io = io_threaded.io();
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const args = try init.args.toSlice(arena.allocator());
    if (args.len != 2) return error.InvalidArguments;

    const address = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    var server = try std.Io.net.IpAddress.listen(&address, io, .{});
    defer server.deinit(io);
    try writePortFile(io, args[1], server.socket.address.getPort());
    var redirect_target_hits: usize = 0;

    while (true) {
        {
            const stream = try server.accept(io);
            defer stream.socket.close(io);
            try serve(io, stream, &redirect_target_hits);
        }
    }
}

fn writePortFile(io: std.Io, path: []const u8, port: u16) !void {
    const file = try std.Io.Dir.createFile(std.Io.Dir.cwd(), io, path, .{});
    defer std.Io.File.close(file, io);
    var buffer: [32]u8 = undefined;
    var writer = std.Io.File.writer(file, io, &buffer);
    try writer.interface.print("{d}\n", .{port});
    try writer.flush();
}

fn serve(io: std.Io, stream: std.Io.net.Stream, redirect_target_hits: *usize) !void {
    var read_buffer: [1024]u8 = undefined;
    var reader = std.Io.net.Stream.reader(stream, io, &read_buffer);
    const request_line = (try reader.interface.takeDelimiter('\n')) orelse return;
    const request_path = requestPath(request_line) orelse return;
    var path_buffer: [256]u8 = undefined;
    const path = path_buffer[0..request_path.len];
    @memcpy(path, request_path);
    var saw_x_test = false;
    var saw_x_other = false;
    while (try reader.interface.takeDelimiter('\n')) |raw_line| {
        const line = std.mem.trimEnd(u8, raw_line, "\r");
        if (line.len == 0) break;
        saw_x_test = saw_x_test or std.ascii.eqlIgnoreCase(line, "X-Test: one");
        saw_x_other = saw_x_other or std.ascii.eqlIgnoreCase(line, "X-Other: two");
    }

    var write_buffer: [1024]u8 = undefined;
    var writer = std.Io.net.Stream.writer(stream, io, &write_buffer);
    if (std.mem.eql(u8, path, "/csv")) return respond(&writer.interface, "200 OK", "text/csv", "id,name\n1,Ada\n");
    if (std.mem.eql(u8, path, "/json")) return respond(&writer.interface, "200 OK", "application/json", "[{\"name\":\"Ada\",\"age\":7}]");
    if (std.mem.eql(u8, path, "/fallback.csv")) return respond(&writer.interface, "200 OK", "application/octet-stream", "name\nAda\n");
    if (std.mem.eql(u8, path, "/override")) return respond(&writer.interface, "200 OK", "text/csv", "[{\"name\":\"Ada\"}]");
    if (std.mem.eql(u8, path, "/headers")) return respond(&writer.interface, if (saw_x_test and saw_x_other) "200 OK" else "401 Unauthorized", "text/csv", "name\nAda\n");
    if (std.mem.eql(u8, path, "/redirect")) return redirect(&writer.interface, "/csv");
    if (std.mem.eql(u8, path, "/redirect-with-header")) return redirect(&writer.interface, "/redirect-target");
    if (std.mem.eql(u8, path, "/redirect-target")) {
        redirect_target_hits.* += 1;
        return respond(&writer.interface, "200 OK", "text/csv", "name\nAda\n");
    }
    if (std.mem.eql(u8, path, "/hits")) {
        var body: [32]u8 = undefined;
        const bytes = try std.fmt.bufPrint(&body, "hits\n{d}\n", .{redirect_target_hits.*});
        return respond(&writer.interface, "200 OK", "text/csv", bytes);
    }
    if (std.mem.startsWith(u8, path, "/redirect-chain/")) {
        const n = std.fmt.parseUnsigned(u8, path[16..], 10) catch return respond(&writer.interface, "400 Bad Request", "text/plain", "");
        if (n == 0) return respond(&writer.interface, "200 OK", "text/csv", "name\nAda\n");
        var location: [32]u8 = undefined;
        const next = try std.fmt.bufPrint(&location, "/redirect-chain/{d}", .{n - 1});
        return redirect(&writer.interface, next);
    }
    if (std.mem.eql(u8, path, "/empty")) return respond(&writer.interface, "200 OK", "text/csv", "");
    if (std.mem.eql(u8, path, "/large")) return respond(&writer.interface, "200 OK", "text/csv", "name\nabcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyz\n");
    return respond(&writer.interface, "404 Not Found", "text/plain", "missing\n");
}

fn requestPath(line: []const u8) ?[]const u8 {
    const start = std.mem.indexOfScalar(u8, line, ' ') orelse return null;
    const end = std.mem.indexOfScalarPos(u8, line, start + 1, ' ') orelse return null;
    return line[start + 1 .. end];
}

fn redirect(writer: *std.Io.Writer, location: []const u8) !void {
    try writer.print("HTTP/1.1 302 Found\r\nLocation: {s}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n", .{location});
    try writer.flush();
}

fn respond(writer: *std.Io.Writer, status: []const u8, content_type: []const u8, body: []const u8) !void {
    try writer.print("HTTP/1.1 {s}\r\nContent-Type: {s}\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}", .{ status, content_type, body.len, body });
    try writer.flush();
}
