const std = @import("std");

pub fn main() !void {
    var buffer = std.ArrayList(u8).empty;
    defer buffer.deinit(std.heap.page_allocator);

    // Read all stdin byte by byte
    var io = std.Io.Threaded.init_single_threaded;
    var stdin_buf: [4096]u8 = undefined;
    var stdin_reader = std.Io.File.reader(std.Io.File.stdin(), io.io(), &stdin_buf);

    while (true) {
        const byte = stdin_reader.interface.takeByte() catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        try buffer.append(std.heap.page_allocator, byte);
    }

    // Compute SHA-256
    var hash: [32]u8 = undefined;
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(buffer.items);
    hasher.final(&hash);

    // Convert to hex
    var hex_buf: [64]u8 = undefined;
    const hex_chars = "0123456789abcdef";
    for (hash, 0..) |byte, i| {
        hex_buf[2 * i] = hex_chars[byte >> 4];
        hex_buf[2 * i + 1] = hex_chars[byte & 0x0F];
    }

    // Output hex
    var stdout_buf: [1024]u8 = undefined;
    var stdout_file_writer = std.Io.File.writer(std.Io.File.stdout(), io.io(), &stdout_buf);
    try stdout_file_writer.interface.writeAll(hex_buf[0..]);
    try stdout_file_writer.interface.writeByte('\n');
    try stdout_file_writer.interface.flush();
}
