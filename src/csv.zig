//! RFC 4180 compliant CSV parser — streaming, single-pass state machine.
//!
//! No full-input buffering: every byte is processed exactly once.
//! Supports:
//!   - Quoted fields enclosed in double-quotes
//!   - Embedded delimiters inside quoted fields
//!   - Escaped double-quotes ("") inside quoted fields → decoded to "
//!   - Embedded newlines (\n, \r\n) inside quoted fields → multi-line value
//!   - Both \r\n and \n record terminators (outside quoted fields)
//!   - Unchanged behaviour for unquoted fields

const std = @import("std");

pub const CsvError = error{
    /// A quoted field was opened but no closing double-quote was found before EOF.
    UnterminatedQuotedField,
};

// ─── State machine ────────────────────────────────────

/// Representation invariant of the parser automaton:
///   field_start  ↔  we are at the start of a new field; `field` is empty
///   unquoted     ↔  we are inside an unquoted field; `field` holds bytes read so far
///   quoted       ↔  we are inside a quoted field (after the opening '"');
///                   `field` holds decoded bytes (excluding the opening quote)
///   quote_saw    ↔  we just read a '"' while in `quoted`;
///                   the quote is either an escape prefix ("") or the closing quote
const State = enum {
    /// Beginning of a new field (no bytes consumed for it yet).
    field_start,
    /// Inside an unquoted field.
    unquoted,
    /// Inside a quoted field (after the opening '"').
    quoted,
    /// Just saw a '"' while in `quoted` — could be "" escape or end-of-field.
    quote_saw,
};

// ─── Public API ───────────────────────────────────────

/// Streaming RFC 4180 CSV record iterator.
///
/// Call `nextRecord` repeatedly to obtain records as `[][]u8`.  Each returned
/// slice, and every field string within it, is heap-allocated; free them with
/// `freeRecord` when done.
///
/// Create with the `csvReader` convenience function:
/// ```zig
/// var csv = csvReader(reader, allocator);
/// while (try csv.nextRecord()) |record| {
///     defer csv.freeRecord(record);
///     // record[0], record[1], …
/// }
/// ```
pub fn CsvReader(comptime ReaderType: type) type {
    return struct {
        reader: ReaderType,
        allocator: std.mem.Allocator,
        delimiter: u8,
        done: bool = false,

        const Self = @This();

        pub fn init(reader: ReaderType, allocator: std.mem.Allocator, delimiter: u8) Self {
            return .{ .reader = reader, .allocator = allocator, .delimiter = delimiter };
        }

        /// Read the next CSV record.
        ///
        /// Pre:  self.done = false  (otherwise returns null immediately)
        ///       self.reader is positioned at the start of the next record
        ///       self.allocator is valid
        /// Post: result = null  ⟺  no more records exist in the input
        ///       result = fields  ⟺  fields is a heap-allocated [][]u8 where
        ///           fields[i] is the UTF-8 content of the i-th field of the record,
        ///           decoded according to RFC 4180 ("" → ", embedded newlines preserved)
        ///       On error.UnterminatedQuotedField: input ended inside a quoted field
        ///       All returned memory must be freed with freeRecord.
        pub fn nextRecord(self: *Self) !?[][]u8 {
            if (self.done) return null;

            var fields = std.ArrayList([]u8){};
            errdefer {
                for (fields.items) |f| self.allocator.free(f);
                fields.deinit(self.allocator);
            }

            var field = std.ArrayList(u8){};
            errdefer field.deinit(self.allocator);

            var state: State = .field_start;
            var has_data = false;

            // Loop invariant I:
            //   `state` satisfies the representation invariant of the automaton.
            //   `field` contains the decoded bytes of the field currently being parsed.
            //   `fields` contains the completed, heap-allocated fields of this record.
            //   All bytes read from `reader` so far have been processed exactly once.
            // Bounding function:
            //   Number of bytes remaining in `reader` (finite input; decreases by 1
            //   each iteration except on the EOF branch which exits immediately).
            while (true) {
                const byte = self.reader.readByte() catch |err| switch (err) {
                    error.EndOfStream => {
                        // EOF: flush whatever pending data we have.
                        if (!has_data and fields.items.len == 0) {
                            field.deinit(self.allocator);
                            fields.deinit(self.allocator);
                            self.done = true;
                            return null;
                        }
                        if (state == .quoted) {
                            field.deinit(self.allocator);
                            for (fields.items) |f| self.allocator.free(f);
                            fields.deinit(self.allocator);
                            return error.UnterminatedQuotedField;
                        }
                        // Flush the last field and return the record.
                        try fields.append(self.allocator, try field.toOwnedSlice(self.allocator));
                        self.done = true;
                        return try fields.toOwnedSlice(self.allocator);
                    },
                    else => return err,
                };

                has_data = true;

                switch (state) {
                    .field_start => {
                        if (byte == self.delimiter) {
                            // Empty unquoted field before delimiter.
                            try fields.append(self.allocator, try field.toOwnedSlice(self.allocator));
                            state = .field_start;
                        } else switch (byte) {
                            '"' => {
                                state = .quoted;
                            },
                            '\r' => {
                                // Part of \r\n; ignore, \n will terminate the record.
                            },
                            '\n' => {
                                // End of record — last field is empty.
                                try fields.append(self.allocator, try field.toOwnedSlice(self.allocator));
                                return try fields.toOwnedSlice(self.allocator);
                            },
                            else => {
                                try field.append(self.allocator, byte);
                                state = .unquoted;
                            },
                        }
                    },

                    .unquoted => {
                        if (byte == self.delimiter) {
                            try fields.append(self.allocator, try field.toOwnedSlice(self.allocator));
                            state = .field_start;
                        } else switch (byte) {
                            '\r' => {
                                // Strip \r before the \n record terminator.
                            },
                            '\n' => {
                                try fields.append(self.allocator, try field.toOwnedSlice(self.allocator));
                                return try fields.toOwnedSlice(self.allocator);
                            },
                            else => {
                                try field.append(self.allocator, byte);
                            },
                        }
                    },

                    .quoted => switch (byte) {
                        '"' => {
                            state = .quote_saw;
                        },
                        // All bytes including \n and \r are part of the field value
                        // when inside a quoted field (RFC 4180 §2.6).
                        else => {
                            try field.append(self.allocator, byte);
                        },
                    },

                    .quote_saw => {
                        if (byte == self.delimiter) {
                            // Closing quote followed by field delimiter.
                            try fields.append(self.allocator, try field.toOwnedSlice(self.allocator));
                            state = .field_start;
                        } else switch (byte) {
                            '"' => {
                                // Escaped double-quote: "" → single "
                                try field.append(self.allocator, '"');
                                state = .quoted;
                            },
                            '\r' => {
                                // Skip \r before \n record terminator.
                            },
                            '\n' => {
                                // Closing quote followed by record terminator.
                                try fields.append(self.allocator, try field.toOwnedSlice(self.allocator));
                                return try fields.toOwnedSlice(self.allocator);
                            },
                            else => {
                                // Non-standard content after closing quote; treat as
                                // continuation of the field in unquoted mode.
                                try field.append(self.allocator, byte);
                                state = .unquoted;
                            },
                        }
                    },
                }
            }
        }

        /// Release a record previously returned by `nextRecord`.
        ///
        /// Pre:  record was returned by nextRecord on this CsvReader instance
        ///       (same allocator); not yet freed.
        /// Post: every field string in record and the record slice itself are freed;
        ///       no further access to record or its elements is valid.
        pub fn freeRecord(self: *Self, record: [][]u8) void {
            for (record) |f| self.allocator.free(f);
            self.allocator.free(record);
        }
    };
}

/// Convenience constructor — infers `ReaderType` from the argument.
pub fn csvReader(allocator: std.mem.Allocator, reader: anytype) CsvReader(@TypeOf(reader)) {
    return csvReaderWithDelimiter(allocator, reader, ',');
}

/// Convenience constructor with custom input delimiter.
pub fn csvReaderWithDelimiter(allocator: std.mem.Allocator, reader: anytype, delimiter: u8) CsvReader(@TypeOf(reader)) {
    return CsvReader(@TypeOf(reader)).init(reader, allocator, delimiter);
}

// ─── Unit Tests ───────────────────────────────────────

test "simple unquoted fields, two records" {
    const input = "a,b,c\n1,2,3\n";
    var stream = std.io.fixedBufferStream(input);
    var csv = csvReader(std.testing.allocator, stream.reader());

    const r1 = (try csv.nextRecord()).?;
    defer csv.freeRecord(r1);
    try std.testing.expectEqual(@as(usize, 3), r1.len);
    try std.testing.expectEqualStrings("a", r1[0]);
    try std.testing.expectEqualStrings("b", r1[1]);
    try std.testing.expectEqualStrings("c", r1[2]);

    const r2 = (try csv.nextRecord()).?;
    defer csv.freeRecord(r2);
    try std.testing.expectEqual(@as(usize, 3), r2.len);
    try std.testing.expectEqualStrings("1", r2[0]);
    try std.testing.expectEqualStrings("2", r2[1]);
    try std.testing.expectEqualStrings("3", r2[2]);

    try std.testing.expectEqual(@as(?[][]u8, null), try csv.nextRecord());
}

test "quoted field with embedded comma" {
    const input = "\"hello, world\",42\n";
    var stream = std.io.fixedBufferStream(input);
    var csv = csvReader(std.testing.allocator, stream.reader());

    const r = (try csv.nextRecord()).?;
    defer csv.freeRecord(r);
    try std.testing.expectEqual(@as(usize, 2), r.len);
    try std.testing.expectEqualStrings("hello, world", r[0]);
    try std.testing.expectEqualStrings("42", r[1]);
}

test "escaped double-quote inside quoted field" {
    const input = "\"say \"\"hello\"\"\",done\n";
    var stream = std.io.fixedBufferStream(input);
    var csv = csvReader(std.testing.allocator, stream.reader());

    const r = (try csv.nextRecord()).?;
    defer csv.freeRecord(r);
    try std.testing.expectEqual(@as(usize, 2), r.len);
    try std.testing.expectEqualStrings("say \"hello\"", r[0]);
    try std.testing.expectEqualStrings("done", r[1]);
}

test "quoted field with embedded newline (multi-line record)" {
    const input = "id,text\n1,\"line one\nline two\"\n";
    var stream = std.io.fixedBufferStream(input);
    var csv = csvReader(std.testing.allocator, stream.reader());

    const r1 = (try csv.nextRecord()).?;
    defer csv.freeRecord(r1);
    try std.testing.expectEqualStrings("id", r1[0]);
    try std.testing.expectEqualStrings("text", r1[1]);

    const r2 = (try csv.nextRecord()).?;
    defer csv.freeRecord(r2);
    try std.testing.expectEqual(@as(usize, 2), r2.len);
    try std.testing.expectEqualStrings("1", r2[0]);
    try std.testing.expectEqualStrings("line one\nline two", r2[1]);

    try std.testing.expectEqual(@as(?[][]u8, null), try csv.nextRecord());
}

test "crlf line endings outside quoted fields" {
    const input = "a,b\r\n1,2\r\n";
    var stream = std.io.fixedBufferStream(input);
    var csv = csvReader(std.testing.allocator, stream.reader());

    const r1 = (try csv.nextRecord()).?;
    defer csv.freeRecord(r1);
    try std.testing.expectEqualStrings("a", r1[0]);
    try std.testing.expectEqualStrings("b", r1[1]);

    const r2 = (try csv.nextRecord()).?;
    defer csv.freeRecord(r2);
    try std.testing.expectEqualStrings("1", r2[0]);
    try std.testing.expectEqualStrings("2", r2[1]);
}

test "empty fields are preserved" {
    const input = ",middle,\n";
    var stream = std.io.fixedBufferStream(input);
    var csv = csvReader(std.testing.allocator, stream.reader());

    const r = (try csv.nextRecord()).?;
    defer csv.freeRecord(r);
    try std.testing.expectEqual(@as(usize, 3), r.len);
    try std.testing.expectEqualStrings("", r[0]);
    try std.testing.expectEqualStrings("middle", r[1]);
    try std.testing.expectEqualStrings("", r[2]);
}

test "no trailing newline at EOF" {
    const input = "x,y";
    var stream = std.io.fixedBufferStream(input);
    var csv = csvReader(std.testing.allocator, stream.reader());

    const r = (try csv.nextRecord()).?;
    defer csv.freeRecord(r);
    try std.testing.expectEqual(@as(usize, 2), r.len);
    try std.testing.expectEqualStrings("x", r[0]);
    try std.testing.expectEqualStrings("y", r[1]);

    try std.testing.expectEqual(@as(?[][]u8, null), try csv.nextRecord());
}

test "quoted field ending at EOF without trailing newline" {
    const input = "\"value\"";
    var stream = std.io.fixedBufferStream(input);
    var csv = csvReader(std.testing.allocator, stream.reader());

    const r = (try csv.nextRecord()).?;
    defer csv.freeRecord(r);
    try std.testing.expectEqual(@as(usize, 1), r.len);
    try std.testing.expectEqualStrings("value", r[0]);
}

test "empty quoted field" {
    const input = "\"\",b\n";
    var stream = std.io.fixedBufferStream(input);
    var csv = csvReader(std.testing.allocator, stream.reader());

    const r = (try csv.nextRecord()).?;
    defer csv.freeRecord(r);
    try std.testing.expectEqual(@as(usize, 2), r.len);
    try std.testing.expectEqualStrings("", r[0]);
    try std.testing.expectEqualStrings("b", r[1]);
}

test "entirely empty input returns null" {
    const input = "";
    var stream = std.io.fixedBufferStream(input);
    var csv = csvReader(std.testing.allocator, stream.reader());

    try std.testing.expectEqual(@as(?[][]u8, null), try csv.nextRecord());
}

test "custom pipe delimiter" {
    const input = "a|b|c\n1|2|3\n";
    var stream = std.io.fixedBufferStream(input);
    var csv = csvReaderWithDelimiter(std.testing.allocator, stream.reader(), '|');

    const r1 = (try csv.nextRecord()).?;
    defer csv.freeRecord(r1);
    try std.testing.expectEqual(@as(usize, 3), r1.len);
    try std.testing.expectEqualStrings("a", r1[0]);
    try std.testing.expectEqualStrings("b", r1[1]);
    try std.testing.expectEqualStrings("c", r1[2]);

    const r2 = (try csv.nextRecord()).?;
    defer csv.freeRecord(r2);
    try std.testing.expectEqual(@as(usize, 3), r2.len);
    try std.testing.expectEqualStrings("1", r2[0]);
    try std.testing.expectEqualStrings("2", r2[1]);
    try std.testing.expectEqualStrings("3", r2[2]);
}

test "custom tab delimiter" {
    const input = "name\tage\nAlice\t30\n";
    var stream = std.io.fixedBufferStream(input);
    var csv = csvReaderWithDelimiter(std.testing.allocator, stream.reader(), '\t');

    const r1 = (try csv.nextRecord()).?;
    defer csv.freeRecord(r1);
    try std.testing.expectEqual(@as(usize, 2), r1.len);
    try std.testing.expectEqualStrings("name", r1[0]);
    try std.testing.expectEqualStrings("age", r1[1]);

    const r2 = (try csv.nextRecord()).?;
    defer csv.freeRecord(r2);
    try std.testing.expectEqual(@as(usize, 2), r2.len);
    try std.testing.expectEqualStrings("Alice", r2[0]);
    try std.testing.expectEqualStrings("30", r2[1]);
}
