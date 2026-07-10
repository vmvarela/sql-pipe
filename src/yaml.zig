//! YAML input loading — reads YAML sequence-of-mappings as rows.
//!
//! loadYamlInput
//!   Read all of `reader` as a YAML document, create table `table_name` in `db`,
//!   and insert every mapping as a row. Expects a top-level YAML sequence of
//!   mappings (list of objects). All columns are TEXT (no type inference).
//!   Comments and flow-style mappings are handled by libyaml transparently.
//!   Multi-document streams, anchors/aliases, non-string keys, and nested
//!   sequences/mappings are rejected with a fatal error.

const std = @import("std");
const c = @import("c");
const yaml = @import("yaml");

const sqlite_helpers = @import("sqlite.zig");

const createAllTextTable = sqlite_helpers.createAllTextTable;
const prepareInsertStmt = sqlite_helpers.prepareInsertStmt;
const beginTransaction = sqlite_helpers.beginTransaction;
const commitTransaction = sqlite_helpers.commitTransaction;
const fatal = sqlite_helpers.fatal;
const ExitCode = sqlite_helpers.ExitCode;
const sqlite_static = sqlite_helpers.sqlite_static;

/// loadYamlInput(allocator, reader, db, table_name, max_rows, stderr_writer) → usize
///
/// Pre:  reader is positioned at the start of a YAML document (single stream)
///       db is an open, empty SQLite database
/// Post: table is created with TEXT columns from the first mapping's keys;
///       all mappings are inserted as rows
///       result = number of rows inserted
///       aborts the process on any parse, I/O, or SQL error
pub fn loadYamlInput(
    allocator: std.mem.Allocator,
    reader: *std.Io.Reader,
    db: *c.sqlite3,
    table_name: []const u8,
    max_rows: ?usize,
    stderr_writer: *std.Io.Writer,
) usize {
    // Read all input into a buffer
    const buf = sqlite_helpers.readAllInput(allocator, reader, stderr_writer, "YAML input");
    defer allocator.free(buf);

    if (buf.len == 0) return 0; // Empty input - return 0 rows gracefully

    // Initialize libyaml parser
    var parser: yaml.yaml_parser_t = undefined;
    if (yaml.yaml_parser_initialize(&parser) != 1)
        fatal("out of memory initializing YAML parser", stderr_writer, .csv_error, .{});
    defer yaml.yaml_parser_delete(&parser);
    yaml.yaml_parser_set_input_string(&parser, @as([*c]const u8, @ptrCast(buf.ptr)), buf.len);

    // State variables
    var cols: std.ArrayList([]const u8) = .empty; // column names (first mapping keys, owned)
    var first_row_vals: std.ArrayList([]const u8) = .empty; // first row's values (owned)
    var current_keys: std.ArrayList([]const u8) = .empty; // keys for current mapping (owned)
    var current_vals: std.ArrayList([]const u8) = .empty; // values for current mapping (owned)
    var current_key: ?[]const u8 = null; // temp key storage (owned when non-null)
    var rows_inserted: usize = 0;
    var got_first_mapping = false;
    var in_transaction = false;
    var stmt: ?*c.sqlite3_stmt = null;
    var mapping_depth: usize = 0;
    var outer_sequence_ended = false; // for multi-doc detection
    var in_outer_sequence = false;

    defer {
        for (cols.items) |c_name| allocator.free(c_name);
        cols.deinit(allocator);
        for (first_row_vals.items) |v| allocator.free(v);
        first_row_vals.deinit(allocator);
        for (current_keys.items) |k| allocator.free(k);
        current_keys.deinit(allocator);
        for (current_vals.items) |v| allocator.free(v);
        current_vals.deinit(allocator);
        if (current_key) |k| allocator.free(k);
        if (stmt) |s| _ = c.sqlite3_finalize(s);
    }

    while (true) {
        var event: yaml.yaml_event_t = undefined;
        if (yaml.yaml_parser_parse(&parser, &event) != 1) {
            const mark = parser.problem_mark;
            const problem = if (parser.problem) |p| std.mem.span(p) else "(unknown)";
            fatal("YAML parse error at line {d}, col {d}: {s}", stderr_writer, .csv_error, .{
                mark.line + 1, mark.column + 1, problem,
            });
        }
        defer yaml.yaml_event_delete(&event);

        switch (@as(c_int, @intCast(event.type))) {
            yaml.YAML_STREAM_START_EVENT => {},
            yaml.YAML_STREAM_END_EVENT => break,

            yaml.YAML_DOCUMENT_START_EVENT => {
                if (outer_sequence_ended)
                    fatal("YAML input: multiple documents not supported (use a single document with one top-level sequence)", stderr_writer, .csv_error, .{});
            },
            yaml.YAML_DOCUMENT_END_EVENT => {},

            yaml.YAML_SEQUENCE_START_EVENT => {
                if (mapping_depth > 0) {
                    // Nested sequence inside a mapping (as key or value)
                    if (current_key == null)
                        fatal("YAML input: mapping keys must be scalar strings", stderr_writer, .csv_error, .{})
                    else
                        fatal("YAML input: mapping values must be scalar strings (nested sequences not supported)", stderr_writer, .csv_error, .{});
                }
                in_outer_sequence = true;
            },
            yaml.YAML_SEQUENCE_END_EVENT => {
                outer_sequence_ended = true;
            },

            yaml.YAML_MAPPING_START_EVENT => {
                mapping_depth += 1;
                if (mapping_depth == 1 and !in_outer_sequence)
                    fatal("YAML input must be a top-level sequence of mappings", stderr_writer, .csv_error, .{});
                if (mapping_depth > 1)
                    fatal("YAML input: nested mappings are not supported", stderr_writer, .csv_error, .{});
                current_key = null;
            },

            yaml.YAML_MAPPING_END_EVENT => {
                mapping_depth -= 1;

                if (!got_first_mapping) {
                    // First mapping: keys define the schema
                    if (current_keys.items.len == 0)
                        fatal("first YAML mapping has no keys", stderr_writer, .csv_error, .{});

                    // Take ownership of current_keys as cols
                    cols = current_keys;
                    current_keys = .empty;
                    first_row_vals = current_vals;
                    current_vals = .empty;

                    createAllTextTable(allocator, db, table_name, cols.items, stderr_writer);
                    beginTransaction(db, stderr_writer);
                    in_transaction = true;
                    stmt = prepareInsertStmt(allocator, db, table_name, cols.items.len, stderr_writer);

                    // Insert first row
                    _ = c.sqlite3_reset(stmt.?);
                    _ = c.sqlite3_clear_bindings(stmt.?);
                    for (first_row_vals.items, 0..) |v, j| {
                        if (c.sqlite3_bind_text(stmt.?, @intCast(j + 1), v.ptr, @intCast(v.len), sqlite_static) != c.SQLITE_OK)
                            fatal("{s}", stderr_writer, .sql_error, .{std.mem.span(c.sqlite3_errmsg(db))});
                    }
                    if (c.sqlite3_step(stmt.?) != c.SQLITE_DONE)
                        fatal("{s}", stderr_writer, .sql_error, .{std.mem.span(c.sqlite3_errmsg(db))});
                    rows_inserted = 1;
                    sqlite_helpers.checkMaxRows(rows_inserted, max_rows, stderr_writer);
                    got_first_mapping = true;
                } else {
                    // Subsequent mappings: bind values by key lookup
                    _ = c.sqlite3_reset(stmt.?);
                    _ = c.sqlite3_clear_bindings(stmt.?);

                    for (cols.items, 0..) |col_name, j| {
                        const param_idx: c_int = @intCast(j + 1);
                        var found = false;
                        for (current_keys.items, current_vals.items) |k, v| {
                            if (std.mem.eql(u8, k, col_name)) {
                                if (c.sqlite3_bind_text(stmt.?, param_idx, v.ptr, @intCast(v.len), sqlite_static) != c.SQLITE_OK)
                                    fatal("{s}", stderr_writer, .sql_error, .{std.mem.span(c.sqlite3_errmsg(db))});
                                found = true;
                                break;
                            }
                        }
                        if (!found) {
                            if (c.sqlite3_bind_null(stmt.?, param_idx) != c.SQLITE_OK)
                                fatal("{s}", stderr_writer, .sql_error, .{std.mem.span(c.sqlite3_errmsg(db))});
                        }
                    }
                    if (c.sqlite3_step(stmt.?) != c.SQLITE_DONE)
                        fatal("{s}", stderr_writer, .sql_error, .{std.mem.span(c.sqlite3_errmsg(db))});
                    rows_inserted += 1;
                    sqlite_helpers.checkMaxRows(rows_inserted, max_rows, stderr_writer);
                }

                // Free current mapping keys and values (except when taken above)
                for (current_keys.items) |k| allocator.free(k);
                for (current_vals.items) |v| allocator.free(v);
                current_keys.items.len = 0;
                current_vals.items.len = 0;
            },

            yaml.YAML_SCALAR_EVENT => {
                const value_slice: []const u8 = @as([*]const u8, @ptrCast(event.data.scalar.value))[0..event.data.scalar.length];
                if (current_key == null) {
                    // This is a key
                    current_key = allocator.dupe(u8, value_slice) catch
                        fatal("out of memory", stderr_writer, .csv_error, .{});
                } else {
                    // This is a value — pair it with the stored key
                    const key = current_key.?;
                    current_key = null;
                    const val_dup = allocator.dupe(u8, value_slice) catch
                        fatal("out of memory", stderr_writer, .csv_error, .{});
                    current_keys.append(allocator, key) catch
                        fatal("out of memory", stderr_writer, .csv_error, .{});
                    current_vals.append(allocator, val_dup) catch
                        fatal("out of memory", stderr_writer, .csv_error, .{});
                }
            },

            yaml.YAML_ALIAS_EVENT => fatal("YAML input: anchors and aliases are not supported", stderr_writer, .csv_error, .{}),
            yaml.YAML_NO_EVENT => unreachable,
            else => {},
        }
    }

    // No rows loaded at all — return 0 (graceful)
    if (cols.items.len == 0) return 0;

    if (in_transaction) commitTransaction(db, stderr_writer);
    return rows_inserted;
}
