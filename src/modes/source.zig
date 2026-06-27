//! Shared helpers for opening input sources in mode commands.
//!
//! Provides `SourceFile` — a file handle with a `needs_close` flag,
//! so callers can uniformly handle file-or-stdin sources.

const std = @import("std");
const fatal = @import("../sqlite.zig").fatal;

/// Result of opening a file-or-stdin input source.
pub const SourceFile = struct {
    file: std.Io.File,
    needs_close: bool,

    /// Close the file if it was opened from a path (no-op for stdin).
    pub fn deinit(self: SourceFile, io: std.Io) void {
        if (self.needs_close) std.Io.File.close(self.file, io);
    }
};

/// Open a file or stdin, handling errors uniformly.
///
/// `input_source` must be a tagged union with `.file: []const u8` and `.stdin` variants.
pub fn openInput(input_source: anytype, io: std.Io, stderr_writer: *std.Io.Writer) SourceFile {
    const source_file = switch (input_source) {
        .file => |path| std.Io.Dir.openFile(std.Io.Dir.cwd(), io, path, .{}) catch |err|
            fatal("cannot open file '{s}': {s}", stderr_writer, .csv_error, .{ path, @errorName(err) }),
        .stdin => std.Io.File.stdin(),
    };
    return .{ .file = source_file, .needs_close = input_source == .file };
}
