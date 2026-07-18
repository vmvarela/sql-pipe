const std = @import("std");
const args_mod = @import("../args.zig");
const columns_mode = @import("columns.zig");
const validate_mode = @import("validate.zig");
const sample_mode = @import("sample.zig");
const stats_mode = @import("stats.zig");
const schema_mode = @import("schema.zig");

pub fn runInspect(
    allocator: std.mem.Allocator,
    io: std.Io,
    mode: args_mod.InspectMode,
    parsed: args_mod.ParsedArgs,
    stderr_writer: *std.Io.Writer,
    stdout_writer: *std.Io.Writer,
) void {
    switch (mode) {
        .columns => columns_mode.runColumns(allocator, io, parsed, stderr_writer, stdout_writer),
        .validate => validate_mode.runValidate(allocator, io, parsed, stderr_writer, stdout_writer),
        .sample => sample_mode.runSample(allocator, io, parsed, stderr_writer, stdout_writer),
        .stats => stats_mode.runStats(allocator, io, parsed, stderr_writer, stdout_writer),
        .schema => schema_mode.runSchema(allocator, io, parsed, stderr_writer, stdout_writer),
    }
}
