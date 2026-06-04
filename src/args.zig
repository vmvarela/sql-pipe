//! CLI argument types and parser for sql-pipe.

const std = @import("std");
const format = @import("format.zig");

const InputFormat = format.InputFormat;
const OutputFormat = format.OutputFormat;

/// Structured exit codes for scripting.
///   0 = success
///   1 = usage error (missing query, bad flag)
///   2 = CSV/parse error
///   3 = SQL error
pub const ExitCode = enum(u8) {
    success = 0,
    usage = 1,
    csv_error = 2,
    sql_error = 3,
};

pub const FileInput = struct {
    path: []const u8,
    table_name: []const u8,
    format: InputFormat,
};

pub const SqlPipeError = error{
    MissingQuery,
    InvalidDelimiter,
    IncompatibleFlags,
    SilentVerboseConflict,
    ColumnsWithQuery,
    ValidateWithQuery,
    ValidateWithColumns,
    OutputWithValidate,
    InvalidMaxRows,
    InvalidInputFormat,
    InvalidOutputFormat,
    MissingXmlFlagValue,
    MissingJsonFlagValue,
    InvalidXmlName,
    JsonPathRequiresJson,
    OpenDbFailed,
    EmptyInput,
    EmptyColumnName,
    NoColumns,
    CreateTableFailed,
    BeginTransactionFailed,
    PrepareInsertFailed,
    BindFailed,
    StepFailed,
    PrepareQueryFailed,
    InvalidOutputPath,
    OutputWithColumns,
    SampleWithQuery,
    SampleWithJson,
    SampleWithColumns,
    SampleWithValidate,
    SampleWithOutput,
    InvalidSampleCount,
    DuplicateTableName,
};

pub const ParsedArgs = struct {
    /// SQL query to execute.
    query: []const u8,
    /// Input files as positional arguments; empty when reading from stdin only.
    files: []const FileInput = &.{},
    /// True when stdin has piped data (not a TTY).
    has_stdin: bool = false,
    /// Infer column types from the first 100 buffered rows when true.
    type_inference: bool,
    /// CSV field delimiter — 1 to 8 bytes (default: ",").
    delimiter: []const u8,
    /// Emit column names as first output row when true (CSV output only).
    header: bool,
    /// Input format (default: csv).
    input_format: InputFormat,
    /// Output format (default: csv).
    output_format: OutputFormat,
    /// Abort with exit 1 when more than this many data rows are read; null = unlimited.
    max_rows: ?usize,
    /// Print "Loaded <n> rows" to stderr after all rows are inserted when true.
    /// When false, the message is still shown automatically when stderr is a TTY.
    verbose: bool,
    /// Suppress "Loaded <n> rows" unconditionally.
    silent: bool,
    /// Write results to this file path instead of stdout; null = write to stdout.
    output: ?[]const u8,
    /// Root element name for XML output (default: "results").
    xml_root: []const u8,
    /// Row element name for XML output (default: "row").
    xml_row: []const u8,
    /// Root element to navigate to for XML input; null = use actual document root.
    xml_root_input: ?[]const u8,
    /// Row tag filter for XML input; null = accept any direct child element as a row.
    xml_row_input: ?[]const u8,
    /// Dot-separated path to the JSON array (e.g. "results.items"); null = expect top-level array.
    json_path: ?[]const u8,
    /// Use a file-backed temporary SQLite database instead of :memory: when true.
    /// Enables processing datasets larger than available RAM; also sets PRAGMA temp_store = FILE.
    disk: bool,
};

pub const ColumnsArgs = struct {
    /// Input files as positional arguments; empty when reading from stdin only.
    files: []const FileInput = &.{},
    /// CSV field delimiter — 1 to 8 bytes (default: ",").
    delimiter: []const u8,
    /// Show inferred type alongside name when true.
    verbose: bool,
    /// Input format (default: csv).
    input_format: InputFormat,
    /// Root element to navigate to for XML input; null = use actual document root.
    xml_root_input: ?[]const u8,
    /// Row tag filter for XML input; null = accept any direct child element as a row.
    xml_row_input: ?[]const u8,
    /// Dot-separated path to the JSON array (e.g. "results.items"); null = expect top-level array.
    json_path: ?[]const u8,
};

pub const ValidateArgs = struct {
    /// Input files as positional arguments; empty when reading from stdin only.
    files: []const FileInput = &.{},
    /// CSV field delimiter — 1 to 8 bytes (default: ",").
    delimiter: []const u8,
    /// Infer column types from the first 100 buffered rows when true.
    type_inference: bool,
    /// Input format (default: csv).
    input_format: InputFormat,
    /// Root element to navigate to for XML input; null = use actual document root.
    xml_root_input: ?[]const u8,
    /// Row tag filter for XML input; null = accept any direct child element as a row.
    xml_row_input: ?[]const u8,
    /// Dot-separated path to the JSON array (e.g. "results.items"); null = expect top-level array.
    json_path: ?[]const u8,
};

pub const SampleArgs = struct {
    /// Input files as positional arguments; empty when reading from stdin only.
    files: []const FileInput = &.{},
    /// CSV field delimiter — 1 to 8 bytes (default: ",").
    delimiter: []const u8,
    /// Input format (default: csv).
    input_format: InputFormat,
    /// Number of sample rows to print (default: 10).
    n: usize,
    /// Infer column types from buffered rows when true; show all TEXT when false.
    type_inference: bool,
};

pub const ArgsResult = union(enum) {
    /// Normal execution: run the query.
    parsed: ParsedArgs,
    /// User requested --help / -h.
    help,
    /// User requested --version / -V.
    version,
    /// User requested --columns: list column names and exit.
    columns: ColumnsArgs,
    /// User requested --validate: parse input and print summary.
    validate: ValidateArgs,
    /// User requested --sample: print schema + first n rows and exit.
    sample: SampleArgs,
};

pub fn printUsage(writer: *std.Io.Writer) !void {
    try writer.writeAll(
        \\Usage: sql-pipe [OPTIONS] <query>
        \\       sql-pipe [OPTIONS] <file>... <query>
        \\
        \\Reads input from stdin and/or file arguments, loads each into an in-memory
        \\SQLite table, runs <query>, and prints results to stdout.
        \\
        \\File arguments: each becomes a table named after its basename (sans extension).
        \\Stdin (when piped) is always loaded into table `t`. Combine files with stdin
        \\for joins: e.g. cat data.csv | sql-pipe lookup.csv 'SELECT ... FROM t JOIN lookup ...'
        \\
        \\Options:
        \\  -d, --delimiter <string>     Input field delimiter for CSV: 1–8 chars (default: ,)
        \\  --tsv                        Alias for --delimiter '\t'
        \\  -I, --input-format <fmt>     Input format: csv (default), tsv, json, ndjson, xml
        \\  -O, --output-format <fmt>    Output format: csv (default), tsv, json, ndjson, xml
        \\  --json                       Alias for --output-format json
        \\  --no-type-inference          Treat all columns as TEXT (CSV input only)
        \\  -H, --header                 Print column names as the first output row (CSV/TSV output only)
        \\  --max-rows <n>               Stop if more than <n> data rows are read (exit 1)
        \\  -v, --verbose                Force row count to stderr (shown automatically on TTY)
        \\                               With --columns: show inferred type per column
        \\  -s, --silent                 Suppress row count output unconditionally
        \\                               Cannot be combined with -v/--verbose
        \\  --validate                   Parse the entire input and print a summary to stdout
        \\                               (OK: <n> rows, <m> columns (<col> <TYPE>, ...))
        \\                               Exit 0 on success, exit 2 on parse error. No query required.
        \\                               Compatible with --delimiter, --tsv, --no-type-inference, -I.
        \\  --columns                    List column names from input header (one per line) and exit
        \\                               Combine with -v/--verbose to include inferred types
        \\                               Cannot be combined with --output or a query argument
        \\  --sample [<n>]               Print schema to stderr and first <n> rows to stdout (default: 10)
        \\                               Schema lists column names and inferred types, prefixed with #
        \\                               Implies --header. Compatible with --delimiter and --tsv.
        \\                               Incompatible with --json and with a query argument.
        \\  --output <file>              Write results to file instead of stdout
        \\  --xml-root <name>            Root element name for XML I/O (default: results)
        \\  --xml-row <name>             Row element name for XML I/O (default: row)
        \\  --json-path <path>           Dot-separated path to the JSON array for -I json (e.g. results.items)
        \\  --disk                       Use a file-backed temp database instead of :memory:
        \\                               Enables processing datasets larger than available RAM
        \\                               Also sets PRAGMA temp_store = FILE for transient structures
        \\  -h, --help                   Show this help message and exit
        \\  -V, --version                Show version and exit
        \\
        \\Exit codes:
        \\  0  Success
        \\  1  Usage error (missing query, bad arguments)
        \\  2  Input parse error
        \\  3  SQL error
        \\
        \\Examples:
        \\  echo 'name,age\nAlice,30' | sql-pipe 'SELECT * FROM t'
        \\  cat data.tsv | sql-pipe --tsv 'SELECT * FROM t'
        \\  cat data.psv | sql-pipe -d '|' 'SELECT * FROM t'
        \\  cat data.csv | sql-pipe 'SELECT region, SUM(revenue) FROM t GROUP BY region'
        \\  sql-pipe orders.csv 'SELECT * FROM orders WHERE amount > 100'
        \\  sql-pipe orders.csv customers.csv 'SELECT c.name, SUM(o.amount) FROM orders o JOIN customers c ON o.cust_id = c.id GROUP BY c.name'
        \\  cat events.csv | sql-pipe users.csv 'SELECT * FROM t JOIN users ON t.uid = users.id'
        \\  cat data.csv | sql-pipe --output-format json 'SELECT * FROM t'
        \\  cat data.json | sql-pipe --input-format json 'SELECT * FROM t'
        \\  cat data.ndjson | sql-pipe -I ndjson -O ndjson 'SELECT name FROM t WHERE age > 18'
        \\  cat data.xml | sql-pipe -I xml --xml-root channel --xml-row item "SELECT title FROM t"
        \\  cat data.csv | sql-pipe --sample 5
        \\
    );
}

pub fn parseDelimiter(value: []const u8) SqlPipeError![]const u8 {
    if (std.mem.eql(u8, value, "\\t")) return "\t";
    if (value.len == 0) return error.InvalidDelimiter;
    if (value.len > 8) return error.InvalidDelimiter;
    return value;
}

pub fn isValidXmlName(s: []const u8) bool {
    if (s.len == 0) return false;
    switch (s[0]) {
        'a'...'z', 'A'...'Z', '_', ':' => {},
        else => return false,
    }
    for (s[1..]) |ch| {
        switch (ch) {
            'a'...'z', 'A'...'Z', '0'...'9', '-', '.', '_', ':' => {},
            else => return false,
        }
    }
    return true;
}

pub fn parseArgs(allocator: std.mem.Allocator, args: []const [:0]const u8) (SqlPipeError || std.mem.Allocator.Error)!ArgsResult {
    var query: ?[]const u8 = null;
    var type_inference = true;
    var delimiter: []const u8 = ",";
    var header = false;
    var input_format: InputFormat = .csv;
    var output_format: OutputFormat = .csv;

    var max_rows: ?usize = null;
    var verbose = false;
    var silent = false;
    var list_columns = false;
    var validate = false;
    var output: ?[]const u8 = null;
    var xml_root: []const u8 = "results";
    var xml_row: []const u8 = "row";
    var xml_root_input: ?[]const u8 = null;
    var xml_row_input: ?[]const u8 = null;
    var json_path: ?[]const u8 = null;
    var sample_mode = false;
    var sample_n: usize = 10;
    var disk = false;
    var seen_dashdash = false;
    var positional_args: std.ArrayList([]const u8) = .empty;
    defer positional_args.deinit(allocator);

    // Loop invariant I: all args[1..i] have been processed;
    //   query holds the first non-flag argument seen, or null;
    //   type_inference reflects the presence of --no-type-inference;
    //   delimiter reflects -d/--delimiter/--tsv if present;
    //   header reflects the presence of --header/-H;
    //   output_format reflects the last --output-format/--json flag seen;
    //   input_format reflects the last --input-format flag seen;
    //   max_rows reflects the presence of --max-rows;
    //   disk reflects the presence of --disk;
    //   positional_args accumulates non-flag arguments for later
    //     conversion into file inputs and the query string;
    //   files is built from positional_args after the loop
    // Bounding function: args.len - i
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (seen_dashdash) {
            try positional_args.append(allocator, arg);
        } else if (std.mem.eql(u8, arg, "--")) {
            seen_dashdash = true;
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            return .help;
        } else if (std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-V")) {
            return .version;
        } else if (std.mem.eql(u8, arg, "--tsv")) {
            delimiter = "\t";
        } else if (std.mem.eql(u8, arg, "-d") or std.mem.eql(u8, arg, "--delimiter")) {
            i += 1;
            if (i >= args.len) return error.InvalidDelimiter;
            delimiter = try parseDelimiter(args[i]);
        } else if (std.mem.startsWith(u8, arg, "--delimiter=")) {
            delimiter = try parseDelimiter(arg["--delimiter=".len..]);
        } else if (std.mem.startsWith(u8, arg, "-d=")) {
            delimiter = try parseDelimiter(arg["-d=".len..]);
        } else if (std.mem.eql(u8, arg, "--no-type-inference")) {
            type_inference = false;
        } else if (std.mem.eql(u8, arg, "--header") or std.mem.eql(u8, arg, "-H")) {
            header = true;
        } else if (std.mem.eql(u8, arg, "--json")) {
            output_format = .json;
        } else if (std.mem.eql(u8, arg, "-I") or std.mem.eql(u8, arg, "--input-format")) {
            i += 1;
            if (i >= args.len) return error.InvalidInputFormat;
            input_format = InputFormat.parse(args[i]) catch return error.InvalidInputFormat;
        } else if (std.mem.startsWith(u8, arg, "--input-format=")) {
            input_format = InputFormat.parse(arg["--input-format=".len..]) catch return error.InvalidInputFormat;
        } else if (std.mem.startsWith(u8, arg, "-I=")) {
            input_format = InputFormat.parse(arg["-I=".len..]) catch return error.InvalidInputFormat;
        } else if (std.mem.eql(u8, arg, "-O") or std.mem.eql(u8, arg, "--output-format")) {
            i += 1;
            if (i >= args.len) return error.InvalidOutputFormat;
            output_format = OutputFormat.parse(args[i]) catch return error.InvalidOutputFormat;
        } else if (std.mem.startsWith(u8, arg, "--output-format=")) {
            output_format = OutputFormat.parse(arg["--output-format=".len..]) catch return error.InvalidOutputFormat;
        } else if (std.mem.startsWith(u8, arg, "-O=")) {
            output_format = OutputFormat.parse(arg["-O=".len..]) catch return error.InvalidOutputFormat;
        } else if (std.mem.eql(u8, arg, "--max-rows")) {
            i += 1;
            if (i >= args.len) return error.InvalidMaxRows;
            max_rows = std.fmt.parseUnsigned(usize, args[i], 10) catch return error.InvalidMaxRows;
            if (max_rows.? == 0) return error.InvalidMaxRows;
        } else if (std.mem.startsWith(u8, arg, "--max-rows=")) {
            max_rows = std.fmt.parseUnsigned(usize, arg["--max-rows=".len..], 10) catch return error.InvalidMaxRows;
            if (max_rows.? == 0) return error.InvalidMaxRows;
        } else if (std.mem.eql(u8, arg, "--verbose") or std.mem.eql(u8, arg, "-v")) {
            verbose = true;
        } else if (std.mem.eql(u8, arg, "--silent") or std.mem.eql(u8, arg, "-s")) {
            silent = true;
        } else if (std.mem.eql(u8, arg, "--columns")) {
            list_columns = true;
        } else if (std.mem.eql(u8, arg, "--validate")) {
            validate = true;
        } else if (std.mem.eql(u8, arg, "--sample")) {
            sample_mode = true;
            // Peek at next arg: if it is a positive integer, consume it as the sample count
            if (i + 1 < args.len) {
                const next = args[i + 1];
                if (next.len > 0 and next[0] != '-') {
                    if (std.fmt.parseUnsigned(usize, next, 10)) |n| {
                        if (n == 0) return error.InvalidSampleCount;
                        sample_n = n;
                        i += 1;
                    } else |_| {
                        // Not a number — keep default (10)
                    }
                }
            }
        } else if (std.mem.startsWith(u8, arg, "--sample=")) {
            const val = arg["--sample=".len..];
            const n = std.fmt.parseUnsigned(usize, val, 10) catch return error.InvalidSampleCount;
            if (n == 0) return error.InvalidSampleCount;
            sample_n = n;
            sample_mode = true;
        } else if (std.mem.eql(u8, arg, "--output")) {
            i += 1;
            if (i >= args.len) return error.InvalidOutputPath;
            const trimmed = std.mem.trim(u8, args[i], " \t");
            if (trimmed.len == 0) return error.InvalidOutputPath;
            output = trimmed;
        } else if (std.mem.startsWith(u8, arg, "--output=")) {
            const trimmed = std.mem.trim(u8, arg["--output=".len..], " \t");
            if (trimmed.len == 0) return error.InvalidOutputPath;
            output = trimmed;
        } else if (std.mem.eql(u8, arg, "--xml-root")) {
            i += 1;
            if (i >= args.len) return error.MissingXmlFlagValue;
            xml_root = args[i];
            xml_root_input = args[i];
        } else if (std.mem.startsWith(u8, arg, "--xml-root=")) {
            xml_root = arg["--xml-root=".len..];
            xml_root_input = arg["--xml-root=".len..];
        } else if (std.mem.eql(u8, arg, "--xml-row")) {
            i += 1;
            if (i >= args.len) return error.MissingXmlFlagValue;
            xml_row = args[i];
            xml_row_input = args[i];
        } else if (std.mem.startsWith(u8, arg, "--xml-row=")) {
            xml_row = arg["--xml-row=".len..];
            xml_row_input = arg["--xml-row=".len..];
        } else if (std.mem.eql(u8, arg, "--json-path")) {
            i += 1;
            if (i >= args.len) return error.MissingJsonFlagValue;
            json_path = args[i];
        } else if (std.mem.startsWith(u8, arg, "--json-path=")) {
            json_path = arg["--json-path=".len..];
        } else if (std.mem.eql(u8, arg, "--disk")) {
            disk = true;
        } else {
            try positional_args.append(allocator, arg);
        }
    }

    // ─── Convert positional args to files + query ──────────────────────────
    const pos = positional_args.items;
    const is_special_mode = list_columns or validate or sample_mode;

    // Build file list from positional args
    var files: std.ArrayList(FileInput) = .empty;

    if (pos.len > 0) {
        if (is_special_mode) {
            // Special modes: every positional arg is a file input
            for (pos) |p| {
                const name = try tableNameFromPath(allocator, p);
                const fmt = InputFormat.fromExtension(p) orelse input_format;
                try files.append(allocator, .{
                    .path = p,
                    .table_name = name,
                    .format = fmt,
                });
            }
        } else {
            // Normal mode: last positional is the query, rest are files
            query = pos[pos.len - 1];
            for (pos[0 .. pos.len - 1]) |p| {
                const name = try tableNameFromPath(allocator, p);
                const fmt = InputFormat.fromExtension(p) orelse input_format;
                try files.append(allocator, .{
                    .path = p,
                    .table_name = name,
                    .format = fmt,
                });
            }
        }
    }

    // Check for duplicate table names (would cause conflicting table definitions)
    {
        var seen = std.StringHashMap(void).init(allocator);
        defer seen.deinit();
        for (files.items) |f| {
            const gop = try seen.getOrPut(f.table_name);
            if (gop.found_existing) return error.DuplicateTableName;
        }
    }

    // Non-CSV/TSV output format is mutually exclusive with --header
    if (output_format != .csv and output_format != .tsv and header)
        return error.IncompatibleFlags;

    // --output is mutually exclusive with --columns (--columns always writes to stdout)
    if (output != null and list_columns)
        return error.OutputWithColumns;

    // --output is mutually exclusive with --validate (--validate always writes to stdout)
    if (output != null and validate)
        return error.OutputWithValidate;

    // --output is mutually exclusive with --sample (--sample always writes to stdout)
    if (output != null and sample_mode)
        return error.SampleWithOutput;

    // --validate is mutually exclusive with --columns
    if (validate and list_columns)
        return error.ValidateWithColumns;

    // --columns is mutually exclusive with a query argument
    if (list_columns and query != null)
        return error.ColumnsWithQuery;

    // --validate is mutually exclusive with a query argument
    if (validate and query != null)
        return error.ValidateWithQuery;

    // --sample is mutually exclusive with a query argument
    if (sample_mode and query != null)
        return error.SampleWithQuery;

    // --sample is mutually exclusive with --json / json output format
    if (sample_mode and (output_format == .json or output_format == .ndjson))
        return error.SampleWithJson;

    // --sample is mutually exclusive with --columns
    if (sample_mode and list_columns)
        return error.SampleWithColumns;

    // --sample is mutually exclusive with --validate
    if (sample_mode and validate)
        return error.SampleWithValidate;

    // --silent and --verbose are mutually exclusive
    if (silent and verbose)
        return error.SilentVerboseConflict;

    // --xml-root and --xml-row must be valid XML element names (only validated in XML mode)
    if (input_format == .xml or output_format == .xml) {
        if (!isValidXmlName(xml_root) or !isValidXmlName(xml_row))
            return error.InvalidXmlName;
    }

    // --json-path requires -I json (the flag only applies to JSON object navigation)
    if (json_path != null and input_format != .json)
        return error.JsonPathRequiresJson;

    // --columns mode: list headers and exit
    if (list_columns)
        return .{ .columns = ColumnsArgs{
            .files = files.items,
            .delimiter = delimiter,
            .verbose = verbose,
            .input_format = input_format,
            .xml_root_input = xml_root_input,
            .xml_row_input = xml_row_input,
            .json_path = json_path,
        } };

    // --validate mode: parse CSV and print summary
    if (validate)
        return .{ .validate = ValidateArgs{
            .files = files.items,
            .delimiter = delimiter,
            .type_inference = type_inference,
            .input_format = input_format,
            .xml_root_input = xml_root_input,
            .xml_row_input = xml_row_input,
            .json_path = json_path,
        } };

    // --sample mode: print schema + first n rows and exit
    if (sample_mode)
        return .{ .sample = SampleArgs{
            .files = files.items,
            .delimiter = delimiter,
            .input_format = input_format,
            .n = sample_n,
            .type_inference = type_inference,
        } };

    return .{ .parsed = ParsedArgs{
        .query = query orelse return error.MissingQuery,
        .files = files.items,
        .type_inference = type_inference,
        .delimiter = delimiter,
        .header = header,
        .input_format = input_format,
        .output_format = output_format,
        .max_rows = max_rows,
        .verbose = verbose,
        .silent = silent,
        .output = output,
        .xml_root = xml_root,
        .xml_row = xml_row,
        .xml_root_input = xml_root_input,
        .xml_row_input = xml_row_input,
        .json_path = json_path,
        .disk = disk,
    } };
}

/// Derive a table name from a file path (basename without extension).
fn tableNameFromPath(allocator: std.mem.Allocator, path: []const u8) (std.mem.Allocator.Error)![]const u8 {
    const stem = std.fs.path.stem(path);
    return allocator.dupe(u8, stem);
}
