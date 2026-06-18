//! Format abstraction — input/output format types and the OutputWriter.
//!
//! This module owns:
//!   InputFormat   — supported input formats, with parse()
//!   OutputFormat  — supported output formats, with parse()
//!   WriteOpts     — options forwarded to OutputWriter
//!   OutputWriter  — stateful writer that dispatches on OutputFormat
//!   writeField    — RFC 4180 CSV field writer (used by OutputWriter and --sample mode)

const std = @import("std");
const c = @import("c");
const json_mod = @import("json.zig");
const sqlite_mod = @import("sqlite.zig");
const xml_mod = @import("xml.zig");

// ─── Input format ──────────────────────────────────────

/// Supported input formats.
pub const InputFormat = enum {
    csv,
    tsv,
    json,
    ndjson,
    xml,

    /// Parse a format name string.
    /// Returns error.InvalidInputFormat when the value is unrecognised.
    pub fn parse(s: []const u8) error{InvalidInputFormat}!InputFormat {
        return std.meta.stringToEnum(InputFormat, s) orelse error.InvalidInputFormat;
    }

    /// Detect input format from file extension.
    /// Returns null for unrecognized extensions.
    pub fn fromExtension(filename: []const u8) ?InputFormat {
        const ext = std.fs.path.extension(filename);
        if (ext.len == 0) return null;
        const ext_no_dot = ext[1..]; // skip the leading '.'
        return std.meta.stringToEnum(InputFormat, ext_no_dot);
    }
};

// ─── Output format ─────────────────────────────────────

/// Supported output formats.
pub const OutputFormat = enum {
    csv,
    tsv,
    json,
    ndjson,
    xml,

    /// Parse a format name string.
    /// Returns error.InvalidOutputFormat when the value is unrecognised.
    pub fn parse(s: []const u8) error{InvalidOutputFormat}!OutputFormat {
        return std.meta.stringToEnum(OutputFormat, s) orelse error.InvalidOutputFormat;
    }
};

// ─── Write options ──────────────────────────────────────

/// Options forwarded to OutputWriter.
pub const WriteOpts = struct {
    /// Emit column names as the first row (CSV/TSV output only).
    header: bool = false,
    /// Root element name for XML output.
    xml_root: []const u8 = "results",
    /// Row element name for XML output.
    xml_row: []const u8 = "row",
};

// ─── Output writer ──────────────────────────────────────

/// Stateful writer that formats SQLite result rows in any supported output format.
///
/// Usage:
///   var w = OutputWriter.init(format, opts);
///   defer w.deinit(allocator);
///   try w.begin(allocator, stmt, col_count, writer);
///   while (sqlite3_step(stmt) == SQLITE_ROW) try w.writeRow(stmt, writer);
///   try w.end(writer);
pub const OutputWriter = struct {
    format: OutputFormat,
    opts: WriteOpts,
    /// Set to false after the first writeRow call; controls JSON comma placement.
    first_row: bool,
    /// Slice of column-name pointers borrowed from SQLite (valid until stmt is finalized).
    /// Allocated in begin(); freed in deinit().
    col_names: []const [*:0]const u8,
    col_count: c_int,
    /// True when col_names was heap-allocated in begin(); false when begin() was never called.
    col_names_allocated: bool,

    /// Create a new OutputWriter. Call begin() before the first writeRow().
    pub fn init(format: OutputFormat, opts: WriteOpts) OutputWriter {
        return .{
            .format = format,
            .opts = opts,
            .first_row = true,
            .col_names = &.{},
            .col_count = 0,
            .col_names_allocated = false,
        };
    }

    /// Release any memory allocated during begin().
    /// Safe to call even when begin() was never called.
    pub fn deinit(self: *OutputWriter, allocator: std.mem.Allocator) void {
        if (self.col_names_allocated) {
            allocator.free(self.col_names);
        }
        self.* = undefined;
    }

    /// Write any format preamble and collect column metadata.
    ///
    /// JSON:    writes '['
    /// XML:     writes the XML declaration and opening root element
    /// CSV/TSV: writes an optional header row (when opts.header = true)
    ///
    /// Pre:  stmt is a valid prepared statement; col_count = sqlite3_column_count(stmt)
    pub fn begin(
        self: *OutputWriter,
        allocator: std.mem.Allocator,
        stmt: *c.sqlite3_stmt,
        col_count: c_int,
        writer: *std.Io.Writer,
    ) !void {
        self.col_count = col_count;

        // Collect column-name pointers for formats that need them per row.
        switch (self.format) {
            .json, .ndjson, .xml => {
                const names = try allocator.alloc([*:0]const u8, @intCast(col_count));
                var i: c_int = 0;
                while (i < col_count) : (i += 1) {
                    names[@intCast(i)] = c.sqlite3_column_name(stmt, i);
                }
                self.col_names = names;
                self.col_names_allocated = true;
            },
            .csv, .tsv => {
                if (self.opts.header and col_count > 0)
                    try csvPrintHeaderRow(stmt, col_count, writer, self.csvDelimiter());
            },
        }

        // Write format-specific preamble.
        switch (self.format) {
            .json => try writer.writeByte('['),
            .xml => try xml_mod.writeXmlHeader(writer, self.opts.xml_root),
            else => {},
        }
    }

    /// Write the current SQLITE_ROW to writer.
    ///
    /// Pre: sqlite3_step(stmt) just returned SQLITE_ROW; begin() has been called
    pub fn writeRow(
        self: *OutputWriter,
        stmt: *c.sqlite3_stmt,
        writer: *std.Io.Writer,
    ) !void {
        switch (self.format) {
            .json => {
                try json_mod.printJsonRow(stmt, self.col_count, self.col_names, writer, self.first_row);
                self.first_row = false;
            },
            .ndjson => try json_mod.printNdjsonRow(stmt, self.col_count, self.col_names, writer),
            .csv, .tsv => try csvPrintRow(stmt, self.col_count, writer, self.csvDelimiter()),
            .xml => try xml_mod.writeXmlRow(
                stmt,
                self.col_count,
                self.col_names,
                writer,
                self.opts.xml_row,
            ),
        }
    }

    /// Write any format epilogue.
    ///
    /// JSON: writes ']\n'
    /// XML:  writes the closing root element
    pub fn end(self: *OutputWriter, writer: *std.Io.Writer) !void {
        switch (self.format) {
            .json => try writer.writeAll("]\n"),
            .xml => try xml_mod.writeXmlFooter(writer, self.opts.xml_root),
            else => {},
        }
    }

    fn csvDelimiter(self: OutputWriter) []const u8 {
        return if (self.format == .tsv) "\t" else ",";
    }
};

// ── CSV output helpers ─────────────────────────────────────────────────────────

/// Write a single CSV/TSV field with RFC 4180 quoting when necessary.
///
/// Pre:  value is a valid UTF-8 slice; delimiter is the field separator string
/// Post: if value contains delimiter, '"', '\n', or '\r', it is enclosed in
///       double-quotes with internal double-quotes doubled; otherwise written verbatim
pub fn writeField(writer: *std.Io.Writer, value: []const u8, delimiter: []const u8) !void {
    const needs_quoting = std.mem.indexOf(u8, value, delimiter) != null or
        std.mem.indexOfAny(u8, value, "\"\n\r") != null;
    if (needs_quoting) {
        try writer.writeByte('"');
        for (value) |ch| {
            if (ch == '"') try writer.writeByte('"');
            try writer.writeByte(ch);
        }
        try writer.writeByte('"');
    } else {
        try writer.writeAll(value);
    }
}

/// Write one delimited output row from the current SQLITE_ROW.
fn csvPrintRow(
    stmt: *c.sqlite3_stmt,
    col_count: c_int,
    writer: *std.Io.Writer,
    delimiter: []const u8,
) !void {
    var i: c_int = 0;
    while (i < col_count) : (i += 1) {
        if (i > 0) try writer.writeAll(delimiter);
        if (c.sqlite3_column_type(stmt, i) == c.SQLITE_NULL) {
            try writer.writeAll("NULL");
        } else {
            if (sqlite_mod.columnText(stmt, i)) |text| {
                try writeField(writer, text, delimiter);
            } else {
                try writer.writeAll("NULL");
            }
        }
    }
    try writer.writeByte('\n');
}

/// Write a header row with column names from the prepared statement.
fn csvPrintHeaderRow(
    stmt: *c.sqlite3_stmt,
    col_count: c_int,
    writer: *std.Io.Writer,
    delimiter: []const u8,
) !void {
    var i: c_int = 0;
    while (i < col_count) : (i += 1) {
        if (i > 0) try writer.writeAll(delimiter);
        if (sqlite_mod.columnName(stmt, i)) |name| {
            try writeField(writer, name, delimiter);
        }
    }
    try writer.writeByte('\n');
}
