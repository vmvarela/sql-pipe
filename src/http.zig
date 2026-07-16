//! HTTP input fetching.

const std = @import("std");
const format = @import("format.zig");
const args_mod = @import("args.zig");

const InputFormat = format.InputFormat;
const SqlPipeError = args_mod.SqlPipeError;

pub const FetchResult = struct {
    body: []u8,
    format: InputFormat,
};

pub fn fetchUrl(
    allocator: std.mem.Allocator,
    io: std.Io,
    url: []const u8,
    headers: []const []const u8,
    max_body_size: usize,
) SqlPipeError!FetchResult {
    const uri = std.Uri.parse(url) catch return error.InvalidUrl;
    if ((!std.ascii.eqlIgnoreCase(uri.scheme, "http") and !std.ascii.eqlIgnoreCase(uri.scheme, "https")) or uri.host == null)
        return error.InvalidUrl;

    var client: std.http.Client = .{ .allocator = allocator, .io = io };
    defer client.deinit();

    var request_headers: std.ArrayList(std.http.Header) = .empty;
    defer request_headers.deinit(allocator);
    for (headers) |header| {
        const colon = std.mem.indexOfScalar(u8, header, ':') orelse return error.InvalidHttpHeader;
        const name = std.mem.trim(u8, header[0..colon], " \t");
        const value = std.mem.trim(u8, header[colon + 1 ..], " \t");
        if (!isSafeHeaderName(name) or hasNewline(value)) return error.InvalidHttpHeader;
        request_headers.append(allocator, .{ .name = name, .value = value }) catch return error.UrlFetchFailed;
    }

    var redirect_buffer: [8 * 1024]u8 = undefined;
    // Pinned Zig does not emit privileged_headers; surface redirects unhandled so custom headers cannot cross origins.
    var request = client.request(.GET, uri, .{
        .redirect_behavior = if (request_headers.items.len == 0) .init(5) else .unhandled,
        .extra_headers = request_headers.items,
        .keep_alive = false,
    }) catch return error.UrlFetchFailed;
    defer request.deinit();

    request.sendBodiless() catch return error.UrlFetchFailed;
    var response = request.receiveHead(&redirect_buffer) catch return error.UrlFetchFailed;
    if (response.head.status.class() != .success) return error.UrlFetchFailed;

    const detected_format = detectFormatFromContentType(response.head.content_type) orelse
        detectFormatFromUrl(url) orelse .csv;

    var transfer_buffer: [8 * 1024]u8 = undefined;
    var decompress: std.http.Decompress = undefined;
    var decompress_buffer: [std.compress.flate.max_window_len]u8 = undefined;
    const body_reader = response.readerDecompressing(&transfer_buffer, &decompress, &decompress_buffer);
    const body = body_reader.allocRemaining(allocator, .limited(max_body_size)) catch return error.UrlFetchFailed;

    return .{ .body = body, .format = detected_format };
}

fn isSafeHeaderName(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name) |byte| switch (byte) {
        '!', '#', '$', '%', '&', '\'', '*', '+', '-', '.', '^', '_', '`', '|', '~', '0'...'9', 'A'...'Z', 'a'...'z' => {},
        else => return false,
    };
    return true;
}

fn hasNewline(value: []const u8) bool {
    return std.mem.indexOfScalar(u8, value, '\r') != null or std.mem.indexOfScalar(u8, value, '\n') != null;
}

fn detectFormatFromContentType(content_type: ?[]const u8) ?InputFormat {
    const content = content_type orelse return null;
    const mime = std.mem.trim(u8, content[0 .. std.mem.indexOfScalar(u8, content, ';') orelse content.len], " \t");
    const mappings = [_]struct { []const u8, InputFormat }{
        .{ "text/csv", .csv },                  .{ "application/csv", .csv },      .{ "text/comma-separated-values", .csv },
        .{ "text/tab-separated-values", .tsv }, .{ "text/tsv", .tsv },             .{ "application/json", .json },
        .{ "application/x-ndjson", .ndjson },   .{ "application/jsonl", .ndjson }, .{ "application/xml", .xml },
        .{ "text/xml", .xml },                  .{ "application/rss+xml", .xml },  .{ "application/atom+xml", .xml },
        .{ "application/yaml", .yaml },         .{ "application/x-yaml", .yaml },  .{ "text/yaml", .yaml },
    };
    for (mappings) |mapping| if (std.ascii.eqlIgnoreCase(mime, mapping[0])) return mapping[1];
    return null;
}

fn detectFormatFromUrl(url: []const u8) ?InputFormat {
    const end = std.mem.indexOfAny(u8, url, "?#") orelse url.len;
    return InputFormat.fromExtension(url[0..end]);
}
