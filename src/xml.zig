//! XML row-based I/O — input loading and output formatting.
//!
//! Input
//! ─────
//!   loadXmlInput      — read row-based XML from stdin, create table `t`, insert rows.
//!   getXmlColumnNames — parse XML and return column names from the first row.
//!   summarizeXml      — parse XML, count rows, return column names (for --validate).
//!
//! Output
//! ──────
//!   writeXmlHeader  — emit the XML declaration and opening root element.
//!   writeXmlRow     — emit one SQLite result row as a compact XML row element.
//!   writeXmlFooter  — emit the closing root element.
//!
//! XML format (output)
//! ───────────────────
//!   <?xml version="1.0" encoding="UTF-8"?>
//!   <results>
//!   <row><name>Alice</name><age>30</age></row>
//!   </results>
//!
//! XML format (input)
//! ──────────────────
//!   Row-based only: each direct child of the root element is a row.
//!   Each child of a row element is a column (element name = column name,
//!   text content = value). Nested elements inside a column are captured as
//!   raw XML strings. Supported entities: &amp; &lt; &gt; &quot; &apos;
//!   CDATA sections are preserved as raw markup.

const std = @import("std");
const c = @import("c");

const sqlite_helpers = @import("sqlite.zig");

const createAllTextTable = sqlite_helpers.createAllTextTable;
const prepareInsertStmt = sqlite_helpers.prepareInsertStmt;
const beginTransaction = sqlite_helpers.beginTransaction;
const commitTransaction = sqlite_helpers.commitTransaction;
const fatal = sqlite_helpers.fatal;
const ExitCode = sqlite_helpers.ExitCode;
const sqlite_static = sqlite_helpers.sqlite_static;

// ─── XML escaping ─────────────────────────────────────

/// writeXmlEscaped(writer, s) → !void
///
/// Pre:  s is a valid UTF-8 slice
/// Post: s is emitted to writer with XML character entity escaping:
///       '&' → "&amp;", '<' → "&lt;", '>' → "&gt;",
///       '"' → "&quot;", '\'' → "&apos;"
pub fn writeXmlEscaped(writer: *std.Io.Writer, s: []const u8) !void {
    for (s) |ch| {
        switch (ch) {
            '&' => try writer.writeAll("&amp;"),
            '<' => try writer.writeAll("&lt;"),
            '>' => try writer.writeAll("&gt;"),
            '"' => try writer.writeAll("&quot;"),
            '\'' => try writer.writeAll("&apos;"),
            else => try writer.writeByte(ch),
        }
    }
}

/// decodeEntities(allocator, s) → ![]u8
///
/// Pre:  s is a valid UTF-8 slice, possibly containing XML entity references
/// Post: &amp;→&, &lt;→<, &gt;→>, &quot;→", &apos;→'
///       Returns a newly allocated slice; caller must free.
fn decodeEntities(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var i: usize = 0;
    // Loop invariant: out contains the decoded prefix of s[0..i]
    // Bounding function: s.len - i
    while (i < s.len) {
        if (s[i] == '&') {
            if (std.mem.startsWith(u8, s[i..], "&amp;")) {
                try out.append(allocator, '&');
                i += 5;
            } else if (std.mem.startsWith(u8, s[i..], "&lt;")) {
                try out.append(allocator, '<');
                i += 4;
            } else if (std.mem.startsWith(u8, s[i..], "&gt;")) {
                try out.append(allocator, '>');
                i += 4;
            } else if (std.mem.startsWith(u8, s[i..], "&quot;")) {
                try out.append(allocator, '"');
                i += 6;
            } else if (std.mem.startsWith(u8, s[i..], "&apos;")) {
                try out.append(allocator, '\'');
                i += 6;
            } else if (std.mem.startsWith(u8, s[i..], "&#")) {
                // Numeric character reference: &#NNN; (decimal) or &#xNNN; (hex)
                const ref_start = i;
                i += 2; // past "&#"
                const is_hex = i < s.len and (s[i] == 'x' or s[i] == 'X');
                if (is_hex) i += 1;
                const digits_start = i;
                while (i < s.len and s[i] != ';') : (i += 1) {}
                if (i < s.len and i > digits_start) {
                    const digits = s[digits_start..i];
                    i += 1; // past ';'
                    const codepoint = if (is_hex)
                        std.fmt.parseInt(u21, digits, 16) catch null
                    else
                        std.fmt.parseInt(u21, digits, 10) catch null;
                    if (codepoint) |cp| {
                        var utf8_buf: [4]u8 = undefined;
                        const len = std.unicode.utf8Encode(cp, &utf8_buf) catch {
                            // Invalid codepoint — pass through as-is
                            try out.appendSlice(allocator, s[ref_start..i]);
                            continue;
                        };
                        try out.appendSlice(allocator, utf8_buf[0..len]);
                        continue;
                    }
                }
                // Malformed numeric reference — pass through as-is
                try out.appendSlice(allocator, s[ref_start..i]);
            } else {
                // Unknown named entity — pass through as-is
                try out.append(allocator, s[i]);
                i += 1;
            }
        } else {
            try out.append(allocator, s[i]);
            i += 1;
        }
    }
    return out.toOwnedSlice(allocator);
}

// ─── Output formatting ────────────────────────────────

/// writeXmlHeader(writer, root_name) → !void
///
/// Pre:  root_name is a valid XML element name
/// Post: XML declaration and opening root element written:
///       <?xml version="1.0" encoding="UTF-8"?>\n<root_name>\n
pub fn writeXmlHeader(writer: *std.Io.Writer, root_name: []const u8) !void {
    try writer.writeAll("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n");
    try writer.writeByte('<');
    try writer.writeAll(root_name);
    try writer.writeAll(">\n");
}

/// writeXmlRow(stmt, col_count, col_names, writer, row_name) → !void
///
/// Pre:  sqlite3_step returned SQLITE_ROW for stmt
///       col_count = sqlite3_column_count(stmt) > 0
///       col_names.len ≥ col_count; row_name is a valid XML element name
/// Post: compact row written: <row_name><col>value</col>...</row_name>\n
///       NULL → empty element body; all text values are XML-escaped
pub fn writeXmlRow(
    stmt: *c.sqlite3_stmt,
    col_count: c_int,
    col_names: []const [*:0]const u8,
    writer: *std.Io.Writer,
    row_name: []const u8,
) !void {
    try writer.writeByte('<');
    try writer.writeAll(row_name);
    try writer.writeByte('>');
    // Loop invariant I: columns 0..i-1 have been written
    // Bounding function: col_count - i
    var i: c_int = 0;
    while (i < col_count) : (i += 1) {
        const name = std.mem.span(col_names[@intCast(i)]);
        try writer.writeByte('<');
        try writer.writeAll(name);
        try writer.writeByte('>');
        switch (c.sqlite3_column_type(stmt, i)) {
            c.SQLITE_NULL => {},
            c.SQLITE_INTEGER => try writer.print("{d}", .{c.sqlite3_column_int64(stmt, i)}),
            c.SQLITE_FLOAT => {
                const f = c.sqlite3_column_double(stmt, i);
                if (f == @trunc(f) and !std.math.isInf(f) and !std.math.isNan(f)) {
                    try writer.print("{d}", .{@as(i64, @intFromFloat(f))});
                } else {
                    try writer.print("{d}", .{f});
                }
            },
            else => {
                const ptr = c.sqlite3_column_text(stmt, i);
                if (ptr != null) {
                    try writeXmlEscaped(writer, std.mem.span(@as([*:0]const u8, @ptrCast(ptr))));
                }
            },
        }
        try writer.writeAll("</");
        try writer.writeAll(name);
        try writer.writeByte('>');
    }
    try writer.writeAll("</");
    try writer.writeAll(row_name);
    try writer.writeAll(">\n");
}

/// writeXmlFooter(writer, root_name) → !void
///
/// Pre:  root_name is a valid XML element name
/// Post: closing root element written: </root_name>\n
pub fn writeXmlFooter(writer: *std.Io.Writer, root_name: []const u8) !void {
    try writer.writeAll("</");
    try writer.writeAll(root_name);
    try writer.writeAll(">\n");
}

// ─── XML Parser ───────────────────────────────────────

/// Minimal row-based XML parser with line/column error reporting.
///
/// Supported constructs:
///   XML declaration, comments, processing instructions (all skipped in prologue)
///   Root element with arbitrary attributes
///   Row elements (direct children of root) with arbitrary attributes
///   Column elements: text content (entities decoded) or nested elements (raw XML)
///   CDATA sections (treated as raw content markup)
///
/// Usage:
///   var p = XmlParser.init(data);
///   p.skipPrologue(err_writer);
///   const root = p.readRootOpen(err_writer);
///   while (try p.nextRow(allocator, root, null, err_writer)) |cols| {
///       defer { for (cols) |col| { if (col.value) |v| allocator.free(v); } allocator.free(cols); }
///       // use cols[i].name and cols[i].value
///   }
pub const XmlParser = struct {
    data: []const u8,
    pos: usize,
    line: usize,
    col: usize,

    /// A single column extracted from a row element.
    pub const Column = struct {
        /// Element name — a slice of the parser's data buffer (not allocated).
        name: []const u8,
        /// Decoded text content, or raw XML for mixed/nested content.
        /// Null for self-closing elements (<tag/>). Owned: free with allocator.
        value: ?[]u8,
    };

    pub fn init(data: []const u8) XmlParser {
        return .{ .data = data, .pos = 0, .line = 1, .col = 1 };
    }

    // ─── Primitives ──────────────────────────────────────

    fn peek(self: *const XmlParser) ?u8 {
        return if (self.pos < self.data.len) self.data[self.pos] else null;
    }

    fn advance(self: *XmlParser) void {
        if (self.pos >= self.data.len) return;
        if (self.data[self.pos] == '\n') {
            self.line += 1;
            self.col = 1;
        } else {
            self.col += 1;
        }
        self.pos += 1;
    }

    fn skipWs(self: *XmlParser) void {
        while (self.peek()) |ch| switch (ch) {
            ' ', '\t', '\r', '\n' => self.advance(),
            else => break,
        };
    }

    fn startsWith(self: *const XmlParser, s: []const u8) bool {
        return self.pos + s.len <= self.data.len and
            std.mem.eql(u8, self.data[self.pos .. self.pos + s.len], s);
    }

    fn fatalAt(self: *const XmlParser, comptime fmt: []const u8, err_writer: *std.Io.Writer, args: anytype) noreturn {
        err_writer.print("error: xml: line {d}, col {d}: ", .{ self.line, self.col }) catch |err| std.log.err("failed to write error: {}", .{err});
        err_writer.print(fmt ++ "\n", args) catch |err| std.log.err("failed to write error: {}", .{err});
        err_writer.flush() catch |err| std.log.err("failed to flush: {}", .{err});
        std.process.exit(@intFromEnum(ExitCode.csv_error));
    }

    // ─── Skip helpers ────────────────────────────────────

    /// Advance past the first occurrence of `delim`; fatal if not found.
    fn skipUntilStr(self: *XmlParser, comptime delim: []const u8, err_writer: *std.Io.Writer) void {
        while (self.pos + delim.len <= self.data.len) {
            if (std.mem.eql(u8, self.data[self.pos .. self.pos + delim.len], delim)) {
                for (delim) |_| self.advance();
                return;
            }
            self.advance();
        }
        self.fatalAt("unexpected end of input looking for '{s}'", err_writer, .{delim});
    }

    fn skipComment(self: *XmlParser, err_writer: *std.Io.Writer) void {
        // Pre: positioned at "<!--"
        self.advance();
        self.advance();
        self.advance();
        self.advance(); // past "<!--"
        self.skipUntilStr("-->", err_writer);
    }

    fn skipProcessingInstruction(self: *XmlParser, err_writer: *std.Io.Writer) void {
        // Pre: positioned at "<?"
        self.advance();
        self.advance(); // past "<?"
        self.skipUntilStr("?>", err_writer);
    }

    fn skipWsAndMisc(self: *XmlParser, err_writer: *std.Io.Writer) void {
        // Loop invariant: all whitespace and misc nodes before self.pos have been consumed
        // Bounding function: self.data.len - self.pos
        while (true) {
            self.skipWs();
            if (self.startsWith("<!--")) self.skipComment(err_writer)
            else if (self.startsWith("<?")) self.skipProcessingInstruction(err_writer)
            else break;
        }
    }

    // ─── Name reading ────────────────────────────────────

    /// Read an XML name; fatal if the current position is not the start of a name.
    fn readName(self: *XmlParser, err_writer: *std.Io.Writer) []const u8 {
        const start = self.pos;
        // XML NameStartChar: letter, '_', ':' (digits not allowed as first char)
        const first = self.peek() orelse self.fatalAt("expected element name", err_writer, .{});
        switch (first) {
            'a'...'z', 'A'...'Z', '_', ':' => self.advance(),
            else => self.fatalAt("expected element name", err_writer, .{}),
        }
        // NameChar: letter, digit, '-', '.', '_', ':'
        while (self.peek()) |ch| switch (ch) {
            'a'...'z', 'A'...'Z', '0'...'9', '-', '.', '_', ':' => self.advance(),
            else => break,
        };
        return self.data[start..self.pos];
    }

    // ─── Tag close ───────────────────────────────────────

    /// Skip attributes and close the tag.  Returns true when self-closing (`/>`).
    fn skipAttrsClose(self: *XmlParser, err_writer: *std.Io.Writer) bool {
        // Loop invariant: all attribute tokens before self.pos consumed
        // Bounding function: distance to '>' or '/>'
        while (true) {
            if (self.peek() == null) self.fatalAt("unexpected end of input in tag", err_writer, .{});
            const ch = self.peek().?;
            if (ch == '>') {
                self.advance();
                return false;
            }
            if (ch == '/' and self.pos + 1 < self.data.len and self.data[self.pos + 1] == '>') {
                self.advance();
                self.advance();
                return true;
            }
            if (ch == '"') {
                self.advance();
                while (self.peek() != null and self.peek().? != '"') self.advance();
                if (self.peek() == null) self.fatalAt("unterminated attribute value", err_writer, .{});
                self.advance(); // closing '"'
            } else if (ch == '\'') {
                self.advance();
                while (self.peek() != null and self.peek().? != '\'') self.advance();
                if (self.peek() == null) self.fatalAt("unterminated attribute value", err_writer, .{});
                self.advance(); // closing '\''
            } else {
                self.advance();
            }
        }
    }

    // ─── Content reading ─────────────────────────────────

    /// Read element content (text and/or nested elements) until the matching close tag.
    ///
    /// Pre:  positioned just after the element's opening tag '>'
    ///       elem_name is the element whose content we are reading
    /// Post: returns an owned allocated slice (caller frees):
    ///         pure text → entities decoded (& < > " ')
    ///         mixed/nested content → raw XML substring (no entity decoding)
    ///       position is just after the closing '</elem_name>'
    fn readContent(
        self: *XmlParser,
        allocator: std.mem.Allocator,
        err_writer: *std.Io.Writer,
        elem_name: []const u8,
    ) ![]u8 {
        const start = self.pos;
        var depth: usize = 0;
        var has_nested = false;
        // Stack of open nested element names (slices into self.data — no allocation per entry).
        // Invariant: tag_stack.items.len == depth at all times.
        var tag_stack: std.ArrayList([]const u8) = .empty;
        defer tag_stack.deinit(allocator);

        // Loop invariant: depth = number of unclosed nested elements
        // Bounding function: self.data.len - self.pos (finite input)
        while (self.pos < self.data.len) {
            if (self.peek().? != '<') {
                self.advance();
                continue;
            }
            if (self.startsWith("<!--")) {
                has_nested = true;
                self.skipComment(err_writer);
            } else if (self.startsWith("<![CDATA[")) {
                has_nested = true;
                for ("<![CDATA[") |_| self.advance();
                self.skipUntilStr("]]>", err_writer);
            } else if (self.startsWith("<?")) {
                self.skipProcessingInstruction(err_writer);
            } else if (self.startsWith("</")) {
                if (depth == 0) {
                    // This is our closing tag
                    const content_end = self.pos;
                    self.advance();
                    self.advance(); // "</"
                    self.skipWs();
                    const close_name = self.readName(err_writer);
                    self.skipWs();
                    if (self.peek() != '>') self.fatalAt("expected '>' after closing tag name", err_writer, .{});
                    self.advance();
                    if (!std.mem.eql(u8, close_name, elem_name))
                        self.fatalAt("expected '</{s}>' but found '</{s}>'", err_writer, .{ elem_name, close_name });
                    const raw = self.data[start..content_end];
                    // Pure text → decode entities; mixed/nested → keep as raw XML
                    if (!has_nested) return decodeEntities(allocator, raw);
                    return allocator.dupe(u8, raw);
                }
                // Closing tag of a nested element — verify name matches the open tag on the stack
                depth -= 1;
                self.advance();
                self.advance(); // "</"
                const close_name = self.readName(err_writer);
                self.skipWs();
                if (self.peek() == '>') self.advance();
                const expected = tag_stack.pop().?; // safe: every closing tag at depth>0 was preceded by an opening push
                if (!std.mem.eql(u8, close_name, expected))
                    self.fatalAt("mismatched closing tag: expected '</{s}>' but found '</{s}>'", err_writer, .{ expected, close_name });
            } else {
                // Opening tag of a nested element
                has_nested = true;
                self.advance(); // '<'
                const nested_name = self.readName(err_writer);
                const self_closing = self.skipAttrsClose(err_writer);
                if (!self_closing) {
                    depth += 1;
                    try tag_stack.append(allocator, nested_name);
                }
            }
        }
        self.fatalAt("unexpected end of input: unclosed element '{s}'", err_writer, .{elem_name});
    }

    // ─── Element skip ────────────────────────────────────

    /// Skip the body and closing tag of an element.
    ///
    /// Pre:  positioned just after the element's opening tag '>'
    /// Post: positioned just after the element's closing '</tag>'
    ///       properly handles nested elements, comments, CDATA, and PIs
    fn skipElementBody(self: *XmlParser, tag: []const u8, err_writer: *std.Io.Writer) void {
        // depth counts unclosed nested elements inside the one we are skipping
        var depth: usize = 0;
        // Loop invariant: depth = number of open nested elements not yet closed
        // Bounding function: self.data.len - self.pos (finite input)
        while (true) {
            const ch = self.peek() orelse break;
            if (ch != '<') {
                self.advance();
                continue;
            }
            if (self.startsWith("<!--")) {
                self.skipComment(err_writer);
            } else if (self.startsWith("<![CDATA[")) {
                for ("<![CDATA[") |_| self.advance();
                self.skipUntilStr("]]>", err_writer);
            } else if (self.startsWith("<?")) {
                self.skipProcessingInstruction(err_writer);
            } else if (self.startsWith("</")) {
                if (depth == 0) {
                    // Closing tag of the element we are skipping — validate name
                    self.advance();
                    self.advance(); // "</"
                    self.skipWs();
                    const close_name = self.readName(err_writer);
                    self.skipWs();
                    if (self.peek() != '>') self.fatalAt("expected '>' after closing tag name", err_writer, .{});
                    self.advance();
                    if (!std.mem.eql(u8, close_name, tag))
                        self.fatalAt("expected '</{s}>' but found '</{s}>'", err_writer, .{ tag, close_name });
                    return;
                }
                // Closing tag of a nested element
                depth -= 1;
                self.advance();
                self.advance(); // "</"
                _ = self.readName(err_writer);
                self.skipWs();
                if (self.peek() == '>') self.advance();
            } else {
                // Opening tag of a nested element (possibly self-closing)
                self.advance(); // '<'
                _ = self.readName(err_writer);
                const self_closing = self.skipAttrsClose(err_writer);
                if (!self_closing) depth += 1;
            }
        }
        self.fatalAt("unexpected end of input: unclosed element '{s}'", err_writer, .{tag});
    }

    // ─── High-level API ──────────────────────────────────

    /// Skip the XML prologue: declaration, processing instructions, comments.
    pub fn skipPrologue(self: *XmlParser, err_writer: *std.Io.Writer) void {
        self.skipWs();
        if (self.startsWith("<?")) self.skipProcessingInstruction(err_writer);
        self.skipWsAndMisc(err_writer);
    }

    /// Expect and consume the root element's opening tag.
    /// Returns the root element name (a slice of the parser's data buffer).
    /// Fatal if the input doesn't start with '<' or if the element is self-closing.
    pub fn readRootOpen(self: *XmlParser, err_writer: *std.Io.Writer) []const u8 {
        if (self.peek() != '<') self.fatalAt("expected '<' to start root element", err_writer, .{});
        self.advance(); // '<'
        const name = self.readName(err_writer);
        const self_closing = self.skipAttrsClose(err_writer);
        if (self_closing) self.fatalAt("root element is self-closing (no rows possible)", err_writer, .{});
        return name;
    }

    /// Navigate to the named container element for row iteration.
    ///
    /// Pre:  skipPrologue() has been called; positioned at the first '<'
    /// Post: positioned just after the opening '>' of the xml_root element
    ///
    /// If the actual document root matches xml_root, it is consumed directly.
    /// Otherwise the actual root is consumed and its direct children are scanned
    /// until xml_root is found; all non-matching children are skipped entirely.
    /// Fatal if xml_root is not found or is self-closing.
    pub fn navigateToRoot(self: *XmlParser, xml_root: []const u8, err_writer: *std.Io.Writer) void {
        if (self.peek() != '<') self.fatalAt("expected '<' to start root element", err_writer, .{});
        self.advance(); // '<'
        const actual_root = self.readName(err_writer);
        const actual_self_closing = self.skipAttrsClose(err_writer);

        // Fast path: actual root already is the target container
        if (std.mem.eql(u8, actual_root, xml_root)) {
            if (actual_self_closing)
                self.fatalAt("element '{s}' is self-closing (no rows possible)", err_writer, .{xml_root});
            return;
        }

        if (actual_self_closing)
            self.fatalAt("element '{s}' not found (actual root '{s}' is self-closing)", err_writer, .{ xml_root, actual_root });

        // Search direct children of the actual root for xml_root
        // Loop invariant: all direct children before current position have been examined
        // Bounding function: distance to end of actual root element (finite)
        while (true) {
            self.skipWsAndMisc(err_writer);
            if (self.peek() == null)
                self.fatalAt("element '{s}' not found in document", err_writer, .{xml_root});
            // Reached end of actual root without finding the target
            if (self.startsWith("</"))
                self.fatalAt("element '{s}' not found as a direct child of '{s}'", err_writer, .{ xml_root, actual_root });
            // Skip text nodes between sibling elements
            if (self.peek() != '<') {
                while (self.peek()) |skip_ch| if (skip_ch != '<') self.advance() else break;
                continue;
            }
            self.advance(); // '<'
            const child_tag = self.readName(err_writer);
            const child_self_closing = self.skipAttrsClose(err_writer);
            if (std.mem.eql(u8, child_tag, xml_root)) {
                if (child_self_closing)
                    self.fatalAt("element '{s}' is self-closing (no rows possible)", err_writer, .{xml_root});
                return;
            }
            // Skip this non-matching child entirely
            if (!child_self_closing) self.skipElementBody(child_tag, err_writer);
        }
    }

    /// Read the next row element from the XML stream.
    ///
    /// Pre:  positioned after the root opening tag (or a previous row's closing tag)
    /// Post: returns null when the root closing tag is reached (no more rows)
    ///       returns an owned slice of Column structs for the next matching row
    ///       caller must free each col.value (when non-null) and the slice itself
    ///
    /// row_tag_filter: when non-null, elements not matching this tag are skipped
    pub fn nextRow(
        self: *XmlParser,
        allocator: std.mem.Allocator,
        root_name: []const u8,
        row_tag_filter: ?[]const u8,
        err_writer: *std.Io.Writer,
    ) !?[]Column {
        // Loop invariant: rows before current position have been processed or skipped
        // Bounding function: distance to root closing tag (finite)
        while (true) {
            self.skipWsAndMisc(err_writer);
            if (self.peek() == null)
                self.fatalAt("unexpected end of input: missing '</{s}>'", err_writer, .{root_name});

            // Root closing tag → end of rows
            if (self.startsWith("</")) {
                self.advance();
                self.advance(); // "</"
                self.skipWs();
                const close_name = self.readName(err_writer);
                if (!std.mem.eql(u8, close_name, root_name))
                    self.fatalAt("expected '</{s}>' but found '</{s}>'", err_writer, .{ root_name, close_name });
                self.skipWs();
                if (self.peek() == '>') self.advance();
                return null;
            }

            // Row opening tag
            if (self.peek() != '<') self.fatalAt("expected '<' to start row element", err_writer, .{});
            self.advance(); // '<'
            const row_tag = self.readName(err_writer);
            const row_self_close = self.skipAttrsClose(err_writer);

            // Skip elements that don't match the row tag filter
            if (row_tag_filter) |filter| {
                if (!std.mem.eql(u8, row_tag, filter)) {
                    if (!row_self_close) self.skipElementBody(row_tag, err_writer);
                    continue;
                }
            }

            var cols: std.ArrayList(Column) = .empty;
            errdefer {
                for (cols.items) |col| if (col.value) |v| allocator.free(v);
                cols.deinit(allocator);
            }

            if (!row_self_close) {
                // Loop invariant: cols contains all column elements of this row parsed so far
                // Bounding function: distance to row closing tag
                while (true) {
                    self.skipWsAndMisc(err_writer);
                    if (self.peek() == null)
                        self.fatalAt("unexpected end of input in row element", err_writer, .{});

                    // Row closing tag
                    if (self.startsWith("</")) {
                        self.advance();
                        self.advance(); // "</"
                        self.skipWs();
                        const close_row = self.readName(err_writer);
                        if (!std.mem.eql(u8, close_row, row_tag))
                            self.fatalAt("expected '</{s}>' but found '</{s}>'", err_writer, .{ row_tag, close_row });
                        self.skipWs();
                        if (self.peek() == '>') self.advance();
                        break;
                    }

                    // Column opening tag
                    if (self.peek() != '<')
                        self.fatalAt("expected '<' to start column element", err_writer, .{});
                    self.advance(); // '<'
                    const col_tag = self.readName(err_writer);
                    const col_self_close = self.skipAttrsClose(err_writer);

                    const value: ?[]u8 = if (col_self_close)
                        null
                    else
                        try self.readContent(allocator, err_writer, col_tag);

                    try cols.append(allocator, .{ .name = col_tag, .value = value });
                }
            }

            const owned = try cols.toOwnedSlice(allocator);
            return owned;
        }
    }
};

// ─── Public input functions ───────────────────────────

/// getXmlColumnNames(allocator, reader, xml_root, xml_row, stderr_writer) → [][]const u8
///
/// Pre:  reader is positioned at the start of a row-based XML document
/// Post: returns an allocated slice of column names (from the first row);
///       caller must free each name and the slice
///       aborts on any parse or I/O error
///
/// xml_root: when non-null, navigate to this element as the row container
/// xml_row:  when non-null, only elements with this tag are treated as rows
pub fn getXmlColumnNames(
    allocator: std.mem.Allocator,
    reader: *std.Io.Reader,
    xml_root: ?[]const u8,
    xml_row: ?[]const u8,
    stderr_writer: *std.Io.Writer,
) [][]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    while (true) {
        const byte = reader.takeByte() catch |err| switch (err) {
            error.EndOfStream => break,
            error.ReadFailed => fatal("failed to read XML input", stderr_writer, .csv_error, .{}),
        };
        buf.append(allocator, byte) catch fatal("out of memory reading XML", stderr_writer, .csv_error, .{});
    }
    if (buf.items.len == 0) fatal("empty input", stderr_writer, .csv_error, .{});

    var p = XmlParser.init(buf.items);
    p.skipPrologue(stderr_writer);
    const root_name: []const u8 = if (xml_root) |r| blk: {
        p.navigateToRoot(r, stderr_writer);
        break :blk r;
    } else p.readRootOpen(stderr_writer);

    const cols = p.nextRow(allocator, root_name, xml_row, stderr_writer) catch
        fatal("out of memory parsing XML", stderr_writer, .csv_error, .{});
    if (cols == null) {
        if (xml_row) |row_tag|
            fatal("XML document has no '{s}' elements (check --xml-row value)", stderr_writer, .csv_error, .{row_tag})
        else
            fatal("XML document has no row elements", stderr_writer, .csv_error, .{});
    }
    defer {
        for (cols.?) |col| if (col.value) |v| allocator.free(v);
        allocator.free(cols.?);
    }

    var names: std.ArrayList([]const u8) = .empty;
    for (cols.?) |col| {
        const owned = allocator.dupe(u8, col.name) catch
            fatal("out of memory", stderr_writer, .csv_error, .{});
        names.append(allocator, owned) catch fatal("out of memory", stderr_writer, .csv_error, .{});
    }
    return names.toOwnedSlice(allocator) catch fatal("out of memory", stderr_writer, .csv_error, .{});
}

/// XmlSummary — result of summarizeXml.
pub const XmlSummary = struct {
    /// Total row element count.
    row_count: usize,
    /// Column names from the first row; all are reported as TEXT.
    /// Owned: caller must free each name and the slice.
    col_names: [][]const u8,
};

/// summarizeXml(allocator, reader, xml_root, xml_row, stderr_writer) → XmlSummary
///
/// Pre:  reader is positioned at the start of a row-based XML document
/// Post: parses the entire document; returns row count and column names
///       aborts on any parse or I/O error
///
/// xml_root: when non-null, navigate to this element as the row container
/// xml_row:  when non-null, only elements with this tag are treated as rows
pub fn summarizeXml(
    allocator: std.mem.Allocator,
    reader: *std.Io.Reader,
    xml_root: ?[]const u8,
    xml_row: ?[]const u8,
    stderr_writer: *std.Io.Writer,
) XmlSummary {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    while (true) {
        const byte = reader.takeByte() catch |err| switch (err) {
            error.EndOfStream => break,
            error.ReadFailed => fatal("failed to read XML input", stderr_writer, .csv_error, .{}),
        };
        buf.append(allocator, byte) catch fatal("out of memory reading XML", stderr_writer, .csv_error, .{});
    }
    if (buf.items.len == 0) fatal("empty input", stderr_writer, .csv_error, .{});

    var p = XmlParser.init(buf.items);
    p.skipPrologue(stderr_writer);
    const root_name: []const u8 = if (xml_root) |r| blk: {
        p.navigateToRoot(r, stderr_writer);
        break :blk r;
    } else p.readRootOpen(stderr_writer);

    var row_count: usize = 0;
    var col_names: ?[][]const u8 = null;

    // Loop invariant: row_count = rows processed so far; col_names set after first row
    // Bounding function: rows remaining in the XML document (finite)
    while (true) {
        const cols = p.nextRow(allocator, root_name, xml_row, stderr_writer) catch
            fatal("out of memory parsing XML", stderr_writer, .csv_error, .{});
        if (cols == null) break;
        defer {
            for (cols.?) |col| if (col.value) |v| allocator.free(v);
            allocator.free(cols.?);
        }
        row_count += 1;
        if (col_names == null) {
            var names: std.ArrayList([]const u8) = .empty;
            for (cols.?) |col| {
                const owned = allocator.dupe(u8, col.name) catch
                    fatal("out of memory", stderr_writer, .csv_error, .{});
                names.append(allocator, owned) catch fatal("out of memory", stderr_writer, .csv_error, .{});
            }
            col_names = names.toOwnedSlice(allocator) catch
                fatal("out of memory", stderr_writer, .csv_error, .{});
        }
    }

    if (col_names == null) {
        if (xml_row) |row_tag|
            fatal("XML document has no '{s}' elements (check --xml-row value)", stderr_writer, .csv_error, .{row_tag})
        else
            fatal("XML document has no row elements", stderr_writer, .csv_error, .{});
    }
    return .{ .row_count = row_count, .col_names = col_names.? };
}

/// loadXmlInput(allocator, reader, db, xml_root, xml_row, max_rows, stderr_writer) → usize
///
/// Pre:  reader is positioned at the start of a row-based XML document
///       db is an open, empty SQLite database
/// Post: table `t` is created with TEXT columns from the first row's element names;
///       all row elements are inserted; transaction is committed
///       result = number of rows inserted
///       aborts the process on any parse, I/O, or SQL error
///
/// xml_root: when non-null, navigate to this element as the row container
/// xml_row:  when non-null, only elements with this tag are treated as rows
pub fn loadXmlInput(
    allocator: std.mem.Allocator,
    reader: *std.Io.Reader,
    db: *c.sqlite3,
    xml_root: ?[]const u8,
    xml_row: ?[]const u8,
    max_rows: ?usize,
    stderr_writer: *std.Io.Writer,
) usize {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    while (true) {
        const byte = reader.takeByte() catch |err| switch (err) {
            error.EndOfStream => break,
            error.ReadFailed => fatal("failed to read XML input", stderr_writer, .csv_error, .{}),
        };
        buf.append(allocator, byte) catch fatal("out of memory reading XML input", stderr_writer, .csv_error, .{});
    }
    if (buf.items.len == 0) fatal("empty input", stderr_writer, .csv_error, .{});

    var p = XmlParser.init(buf.items);
    p.skipPrologue(stderr_writer);
    const root_name: []const u8 = if (xml_root) |r| blk: {
        p.navigateToRoot(r, stderr_writer);
        break :blk r;
    } else p.readRootOpen(stderr_writer);

    // Column names determined from the first row; kept for schema consistency
    var col_names: ?[][]const u8 = null;
    defer if (col_names) |names| {
        for (names) |n| allocator.free(n);
        allocator.free(names);
    };

    var insert_stmt: ?*c.sqlite3_stmt = null;
    defer if (insert_stmt) |s| {
        _ = c.sqlite3_finalize(s);
    };

    var rows_inserted: usize = 0;
    var in_transaction = false;

    // Loop invariant: rows_inserted = rows inserted so far;
    //   col_names and insert_stmt are set after the first row is processed;
    //   in_transaction = true after the first insert
    // Bounding function: row elements remaining in the document (finite)
    while (true) {
        const cols = p.nextRow(allocator, root_name, xml_row, stderr_writer) catch
            fatal("out of memory parsing XML", stderr_writer, .csv_error, .{});
        if (cols == null) break;

        defer {
            for (cols.?) |col| if (col.value) |v| allocator.free(v);
            allocator.free(cols.?);
        }

        rows_inserted += 1;
        if (max_rows) |limit| {
            if (rows_inserted > limit)
                fatal("input exceeds --max-rows limit ({d} rows)", stderr_writer, .usage, .{limit});
        }

        if (col_names == null) {
            // First row: extract schema, create table, begin transaction
            var names: std.ArrayList([]const u8) = .empty;
            for (cols.?) |col| {
                const owned = allocator.dupe(u8, col.name) catch
                    fatal("out of memory", stderr_writer, .csv_error, .{});
                names.append(allocator, owned) catch fatal("out of memory", stderr_writer, .csv_error, .{});
            }
            if (names.items.len == 0)
                fatal("first XML row element has no column children", stderr_writer, .csv_error, .{});
            col_names = names.toOwnedSlice(allocator) catch fatal("out of memory", stderr_writer, .csv_error, .{});

            createAllTextTable(allocator, db, col_names.?, stderr_writer);
            beginTransaction(db, stderr_writer);
            in_transaction = true;
            insert_stmt = prepareInsertStmt(allocator, db, col_names.?.len, stderr_writer);
        }

        // Bind column values by name (order in row may differ from schema order)
        const stmt = insert_stmt.?;
        _ = c.sqlite3_reset(stmt);
        _ = c.sqlite3_clear_bindings(stmt);

        // Loop invariant: params 1..j bound for col_names[0..j-1]
        // Bounding function: col_names.?.len - j
        for (col_names.?, 0..) |col_name, j| {
            const param_idx: c_int = @intCast(j + 1);
            // Find this column's value in the current row (linear search; n is small)
            const value: ?[]u8 = blk: {
                for (cols.?) |col| {
                    if (std.mem.eql(u8, col.name, col_name)) break :blk col.value;
                }
                break :blk null; // column absent in this row → NULL
            };
            if (value) |v| {
                if (c.sqlite3_bind_text(stmt, param_idx, v.ptr, @intCast(v.len), sqlite_static) != c.SQLITE_OK)
                    fatal("{s}", stderr_writer, .sql_error, .{std.mem.span(c.sqlite3_errmsg(db))});
            } else {
                if (c.sqlite3_bind_null(stmt, param_idx) != c.SQLITE_OK)
                    fatal("{s}", stderr_writer, .sql_error, .{std.mem.span(c.sqlite3_errmsg(db))});
            }
        }

        if (c.sqlite3_step(stmt) != c.SQLITE_DONE)
            fatal("{s}", stderr_writer, .sql_error, .{std.mem.span(c.sqlite3_errmsg(db))});
    }

    if (col_names == null) {
        if (xml_row) |row_tag|
            fatal("XML document has no '{s}' elements (check --xml-row value)", stderr_writer, .csv_error, .{row_tag})
        else
            fatal("XML document has no row elements", stderr_writer, .csv_error, .{});
    }
    if (in_transaction) commitTransaction(db, stderr_writer);
    return rows_inserted;
}

// ─── Unit tests ───────────────────────────────────────

test "decodeEntities: predefined XML entities" {
    const allocator = std.testing.allocator;
    const result = try decodeEntities(allocator, "&amp;&lt;&gt;&quot;&apos;");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("&<>\"'", result);
}

test "decodeEntities: plain text unchanged" {
    const allocator = std.testing.allocator;
    const result = try decodeEntities(allocator, "hello world");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("hello world", result);
}

test "decodeEntities: unknown entity passthrough" {
    const allocator = std.testing.allocator;
    const result = try decodeEntities(allocator, "&copy;");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("&copy;", result);
}

test "decodeEntities: numeric decimal reference" {
    const allocator = std.testing.allocator;
    const result = try decodeEntities(allocator, "&#65;"); // 'A'
    defer allocator.free(result);
    try std.testing.expectEqualStrings("A", result);
}

test "decodeEntities: numeric hex reference" {
    const allocator = std.testing.allocator;
    const result = try decodeEntities(allocator, "&#x41;"); // 'A'
    defer allocator.free(result);
    try std.testing.expectEqualStrings("A", result);
}

test "writeXmlEscaped: escapes special characters" {
    var buf: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try writeXmlEscaped(&writer, "a&b<c>d\"e'f");
    const written = std.Io.Writer.buffered(&writer);
    try std.testing.expectEqualStrings("a&amp;b&lt;c&gt;d&quot;e&apos;f", written);
}

test "writeXmlEscaped: plain text unchanged" {
    var buf: [64]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try writeXmlEscaped(&writer, "hello world 123");
    const written = std.Io.Writer.buffered(&writer);
    try std.testing.expectEqualStrings("hello world 123", written);
}

test "writeXmlHeader and writeXmlFooter" {
    var buf: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try writeXmlHeader(&writer, "results");
    try writeXmlFooter(&writer, "results");
    const written = std.Io.Writer.buffered(&writer);
    try std.testing.expectEqualStrings(
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<results>\n</results>\n",
        written,
    );
}

test "XmlParser.nextRow: simple row with two columns" {
    const allocator = std.testing.allocator;
    var err_buf: [256]u8 = undefined;
    var err_writer: std.Io.Writer = .fixed(&err_buf);

    const input = "<results><row><name>Alice</name><age>30</age></row></results>";
    var p = XmlParser.init(input);
    p.skipPrologue(&err_writer);
    const root = p.readRootOpen(&err_writer);
    try std.testing.expectEqualStrings("results", root);

    const cols = try p.nextRow(allocator, root, null, &err_writer);
    try std.testing.expect(cols != null);
    defer {
        for (cols.?) |col| if (col.value) |v| allocator.free(v);
        allocator.free(cols.?);
    }
    try std.testing.expectEqual(@as(usize, 2), cols.?.len);
    try std.testing.expectEqualStrings("name", cols.?[0].name);
    try std.testing.expectEqualStrings("Alice", cols.?[0].value.?);
    try std.testing.expectEqualStrings("age", cols.?[1].name);
    try std.testing.expectEqualStrings("30", cols.?[1].value.?);

    // No more rows
    const next = try p.nextRow(allocator, root, null, &err_writer);
    try std.testing.expect(next == null);
}

test "XmlParser.nextRow: self-closing column is null" {
    const allocator = std.testing.allocator;
    var err_buf: [256]u8 = undefined;
    var err_writer: std.Io.Writer = .fixed(&err_buf);

    const input = "<r><row><name/><age>5</age></row></r>";
    var p = XmlParser.init(input);
    p.skipPrologue(&err_writer);
    const root = p.readRootOpen(&err_writer);

    const cols = try p.nextRow(allocator, root, null, &err_writer);
    try std.testing.expect(cols != null);
    defer {
        for (cols.?) |col| if (col.value) |v| allocator.free(v);
        allocator.free(cols.?);
    }
    try std.testing.expectEqual(@as(usize, 2), cols.?.len);
    try std.testing.expectEqualStrings("name", cols.?[0].name);
    try std.testing.expect(cols.?[0].value == null); // self-closing → null
    try std.testing.expectEqualStrings("5", cols.?[1].value.?);
}

test "XmlParser.nextRow: entities decoded in content" {
    const allocator = std.testing.allocator;
    var err_buf: [256]u8 = undefined;
    var err_writer: std.Io.Writer = .fixed(&err_buf);

    const input = "<r><row><val>Alice &amp; Bob &lt;test&gt;</val></row></r>";
    var p = XmlParser.init(input);
    p.skipPrologue(&err_writer);
    const root = p.readRootOpen(&err_writer);

    const cols = try p.nextRow(allocator, root, null, &err_writer);
    try std.testing.expect(cols != null);
    defer {
        for (cols.?) |col| if (col.value) |v| allocator.free(v);
        allocator.free(cols.?);
    }
    try std.testing.expectEqualStrings("Alice & Bob <test>", cols.?[0].value.?);
}

test "XmlParser.nextRow: empty document returns null" {
    const allocator = std.testing.allocator;
    var err_buf: [256]u8 = undefined;
    var err_writer: std.Io.Writer = .fixed(&err_buf);

    const input = "<r></r>";
    var p = XmlParser.init(input);
    p.skipPrologue(&err_writer);
    const root = p.readRootOpen(&err_writer);

    const cols = try p.nextRow(allocator, root, null, &err_writer);
    try std.testing.expect(cols == null);
}

test "XmlParser: XML declaration in prologue" {
    var err_buf: [256]u8 = undefined;
    var err_writer: std.Io.Writer = .fixed(&err_buf);

    const input = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<results></results>";
    var p = XmlParser.init(input);
    p.skipPrologue(&err_writer);
    const root = p.readRootOpen(&err_writer);
    try std.testing.expectEqualStrings("results", root);
}

test "XmlParser.skipElementBody: skips body and validates closing tag" {
    var err_buf: [256]u8 = undefined;
    var err_writer: std.Io.Writer = .fixed(&err_buf);

    // Parser positioned just after <skip>'s '>' — body + closing tag + next element
    const input = "<inner>text</inner></skip><keep/>";
    var p = XmlParser.init(input);
    p.skipElementBody("skip", &err_writer);
    // Should now be positioned at "<keep/>"
    try std.testing.expectEqualStrings("<keep/>", p.data[p.pos..]);
}

test "XmlParser.skipElementBody: handles nested elements" {
    var err_buf: [256]u8 = undefined;
    var err_writer: std.Io.Writer = .fixed(&err_buf);

    const input = "<a><b><c>x</c></b></a></skip>tail";
    var p = XmlParser.init(input);
    p.skipElementBody("skip", &err_writer);
    try std.testing.expectEqualStrings("tail", p.data[p.pos..]);
}

test "XmlParser.navigateToRoot: fast path — actual root matches" {
    var err_buf: [256]u8 = undefined;
    var err_writer: std.Io.Writer = .fixed(&err_buf);

    const input = "<channel><item><title>Test</title></item></channel>";
    var p = XmlParser.init(input);
    p.skipPrologue(&err_writer);
    p.navigateToRoot("channel", &err_writer);
    try std.testing.expectEqualStrings("<item><title>Test</title></item></channel>", p.data[p.pos..]);
}

test "XmlParser.navigateToRoot: finds nested container as direct child" {
    var err_buf: [256]u8 = undefined;
    var err_writer: std.Io.Writer = .fixed(&err_buf);

    const input = "<rss><meta><v>1</v></meta><channel><item><n>T</n></item></channel></rss>";
    var p = XmlParser.init(input);
    p.skipPrologue(&err_writer);
    p.navigateToRoot("channel", &err_writer);
    try std.testing.expectEqualStrings("<item><n>T</n></item></channel></rss>", p.data[p.pos..]);
}

test "XmlParser.navigateToRoot: handles text nodes between siblings" {
    var err_buf: [256]u8 = undefined;
    var err_writer: std.Io.Writer = .fixed(&err_buf);

    const input = "<rss>some text<channel><item/></channel></rss>";
    var p = XmlParser.init(input);
    p.skipPrologue(&err_writer);
    p.navigateToRoot("channel", &err_writer);
    try std.testing.expectEqualStrings("<item/></channel></rss>", p.data[p.pos..]);
}

test "XmlParser.readContent: properly matched nested tags are accepted" {
    const allocator = std.testing.allocator;
    var err_buf: [256]u8 = undefined;
    var err_writer: std.Io.Writer = .fixed(&err_buf);

    // Deeply nested content with correctly matched tags — stack must track them all
    const input = "<r><row><col><a><b>text</b></a></col></row></r>";
    var p = XmlParser.init(input);
    p.skipPrologue(&err_writer);
    const root = p.readRootOpen(&err_writer);

    const cols = try p.nextRow(allocator, root, null, &err_writer);
    try std.testing.expect(cols != null);
    defer {
        for (cols.?) |col| if (col.value) |v| allocator.free(v);
        allocator.free(cols.?);
    }
    try std.testing.expectEqual(@as(usize, 1), cols.?.len);
    try std.testing.expectEqualStrings("col", cols.?[0].name);
    // Mixed/nested content is returned as raw XML substring
    try std.testing.expectEqualStrings("<a><b>text</b></a>", cols.?[0].value.?);
}

test "XmlParser.nextRow: row_tag_filter skips non-matching elements" {
    const allocator = std.testing.allocator;
    var err_buf: [256]u8 = undefined;
    var err_writer: std.Io.Writer = .fixed(&err_buf);

    const input = "<root><meta><x>1</x></meta><item><name>Alice</name></item>" ++
        "<meta><x>2</x></meta><item><name>Bob</name></item></root>";
    var p = XmlParser.init(input);
    p.skipPrologue(&err_writer);
    const root = p.readRootOpen(&err_writer);

    const row1 = try p.nextRow(allocator, root, "item", &err_writer);
    try std.testing.expect(row1 != null);
    defer {
        for (row1.?) |col| if (col.value) |v| allocator.free(v);
        allocator.free(row1.?);
    }
    try std.testing.expectEqualStrings("Alice", row1.?[0].value.?);

    const row2 = try p.nextRow(allocator, root, "item", &err_writer);
    try std.testing.expect(row2 != null);
    defer {
        for (row2.?) |col| if (col.value) |v| allocator.free(v);
        allocator.free(row2.?);
    }
    try std.testing.expectEqualStrings("Bob", row2.?[0].value.?);

    const row3 = try p.nextRow(allocator, root, "item", &err_writer);
    try std.testing.expect(row3 == null);
}
