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

/// Controls pretty-printed table output.
///   auto   — show table when stdout is a TTY, CSV when piped (default)
///   always — force table output regardless of TTY
///   never  — force CSV output regardless of TTY
pub const TableMode = enum {
    auto,
    always,
    never,
};

pub const FileInput = struct {
    path: []const u8,
    table_name: []const u8,
    format: InputFormat,
};

pub const UrlInput = struct {
    url: []const u8,
    table_name: ?[]const u8,
    format: ?InputFormat,
    headers: []const []const u8,
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
    InvalidSavePath,
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
    SaveIncompatibleDisk,
    SaveIncompatibleMode,
    SampleWithValidate,
    SampleWithOutput,
    InvalidSampleCount,
    StatsWithFlags,
    SchemaWithFlags,
    DuplicateTableName,
    TableWithNonCsv,
    InvalidQueryFile,
    MultipleQueryFiles,
    MissingSqlTableValue,
    ExplainWithFlags,
    MissingNullValue,
    MissingHtmlClassValue,
    InvalidCompletionsShell,
    InvalidUrl,
    InvalidHttpHeader,
    InvalidMaxBodySize,
    HttpFlagsRequireUrl,
    UrlIncompatibleMode,
    UrlFetchFailed,
    ReplIncompatibleMode,
    ReplWithQueryFile,
    ReplWithOutput,
    ReplIncompatibleExplain,
    DuplicateUrlTableName,
    UrlHeaderRequiresUrl,
    InspectWithQuery,
    InspectWithOutput,
    InspectWithExplain,
    InspectSampleWithJson,
    InvalidInspectMode,
    MissingInspectMode,
    ExplainWithOutput,
};

pub const ParsedArgs = struct {
    /// SQL query to execute.
    query: []const u8,
    /// Path to file containing SQL query (when using -f/--file); null = query from positional arg.
    query_file: ?[]const u8 = null,
    /// Input files as positional arguments; empty when reading from stdin only.
    files: []const FileInput = &.{},
    /// URLs to fetch input data from (repeatable); empty when not using HTTP input.
    urls: []const UrlInput = &.{},
    /// True when stdin has piped data (not a TTY).
    has_stdin: bool = false,
    /// Infer column types from the first 100 buffered rows when true.
    type_inference: bool,
    /// True when --no-stdin flag is set (skip stdin even when piped).
    no_stdin: bool = false,
    /// CSV field delimiter — 1 to 8 bytes (default: ",").
    delimiter: []const u8,
    /// Emit column names as first output row when true (CSV output only).
    header: bool,
    /// Input format (default: csv).
    input_format: InputFormat,
    /// Whether -I/--input-format was explicitly provided (vs auto-detected).
    input_format_explicit: bool = false,
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
    /// Path to save the SQLite database to (when --save/-S is used).
    /// When set, the DB is opened at this path directly (file-backed).
    save_path: ?[:0]const u8 = null,
    /// Print EXPLAIN QUERY PLAN to stderr before executing the query.
    explain: bool = false,
    /// Pretty-printed table output mode (default: auto — TTY detection).
    table_mode: TableMode = .auto,
    /// Target table name for SQL INSERT output (default: "t").
    sql_table: []const u8 = "t",
    /// CSS class name for the HTML <table> element (default: "" = no class).
    html_class: []const u8 = "",
    /// Custom string for NULL values in output (default: "NULL" for CSV/TSV/table).
    null_value: ?[]const u8 = null,
    /// Maximum response body size in bytes for --url (default: 100MB).
    max_body_size: usize = 100 * 1024 * 1024,
    /// When set, run in --inspect mode instead of normal query mode.
    inspect_args: ?InspectArgs = null,
    /// Number of sample rows to print when in --inspect sample mode (default: 10).
    sample_n: usize = 10,
};

pub const CompletionsShell = enum {
    bash,
    zsh,
    fish,

    pub fn parse(s: []const u8) error{InvalidCompletionsShell}!CompletionsShell {
        return std.meta.stringToEnum(CompletionsShell, s) orelse error.InvalidCompletionsShell;
    }
};

pub const CompletionsArgs = struct {
    shell: CompletionsShell,
};

pub const InspectMode = enum {
    columns,
    validate,
    sample,
    stats,
    schema,

    pub fn parse(s: []const u8) error{InvalidInspectMode}!InspectMode {
        return std.meta.stringToEnum(InspectMode, s) orelse error.InvalidInspectMode;
    }
};

pub const InspectArgs = struct {
    mode: InspectMode,
    sample_n: usize = 10,
    deprecated: bool = false,
};

pub const ArgsResult = union(enum) {
    /// Normal execution: run the query (requires query positional arg unless --repl is set).
    parsed: ParsedArgs,
    /// User requested --repl: enter interactive REPL after loading data.
    repl: ParsedArgs,
    /// User requested --help / -h.
    help,
    /// User requested --version / -V.
    version,
    /// User requested --inspect or old flag: run one of the inspect modes.
    inspect: ParsedArgs,
    /// User requested --completions: generate shell completion script.
    completions: CompletionsArgs,
};

pub fn printUsage(writer: *std.Io.Writer) !void {
    try writer.writeAll(
        \\Usage: sql-pipe [OPTIONS] <query>
        \\       sql-pipe [OPTIONS] <file>... <query>
        \\       sql-pipe -f <file> [OPTIONS] [<file>...]
        \\       sql-pipe --repl [OPTIONS] [<file>...]
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
        \\  -I, --input-format <fmt>     Input format: csv (default), tsv, json, ndjson, xml, yaml, parquet
        \\                               Overrides file extension auto-detection; stdin always uses this value
        \\  -O, --output-format <fmt>    Output format: csv (default), tsv, json, ndjson, xml, markdown (alias: md), html, sql
        \\  --json                       Alias for --output-format json
        \\  --sql-table <name>           Target table name for -O sql INSERT output (default: t)
        \\  --no-type-inference          Treat all columns as TEXT (CSV input only)
        \\  --no-stdin                   Do not read from stdin (prevent hang in CI)
        \\  -H, --header                 Print column names as the first output row (CSV/TSV/HTML)
        \\  --max-rows <n>               Stop if more than <n> data rows are read (exit 1)
        \\  -v, --verbose                Force row count to stderr (shown automatically on TTY)
        \\                               With --columns: show inferred type per column
        \\  -s, --silent                 Suppress row count output unconditionally
        \\                               Cannot be combined with -v/--verbose
        \\  --inspect <mode>             Inspect mode: columns, validate, sample, stats, schema
        \\                               columns — list column names (use -v for types)
        \\                               validate — parse and print summary (exit 2 on error)
        \\                               sample [n] — print schema to stderr and n rows to stdout (default: 10)
        \\                               stats — per-column statistics (type, non-null, min, max, mean)
        \\                               schema — print inferred CREATE TABLE DDL
        \\  --sample [<n>]               (deprecated) Print schema and first <n> rows, use --inspect sample
        \\  --output <file>              Write results to file instead of stdout
        \\  --xml-root <name>            Root element name for XML I/O (default: results)
        \\  --xml-row <name>             Row element name for XML I/O (default: row)
        \\  --json-path <path>           Dot-separated path to the JSON array for -I json (e.g. results.items)
        \\  --disk                       Use a file-backed temp database instead of :memory:
        \\                               Enables processing datasets larger than available RAM
        \\                               Also sets PRAGMA temp_store = FILE for transient structures
        \\  --save <file> / -S <file>    Use <file> as the SQLite database (disk-backed, persisted)
        \\  --explain                    Print SQLite query plan to stderr before executing
        \\  -r, --repl                   Enter interactive REPL after loading input data.
        \\                               No query required. Type .exit, .quit, .q, Ctrl-D, or Ctrl-C to quit.
        \\                               Arrow-key history via linenoise; persisted at $HOME/.sqlpipe_history.
        \\                               Incompatible with special modes, -f/--file, --explain, and --output.
        \\                               Compatible with --save, --disk, -O, and file arguments.
        \\  --table                      Force pretty-printed table output (auto-detected on TTY)
        \\  --no-table                   Force CSV output even when stdout is a TTY
        \\  --null-value <string>        Custom NULL representation in output (default: "NULL" for CSV/TSV/table)
        \\  --html-class <class>         CSS class name for the HTML <table> element (-O html only)
        \\  -f, --file <file>            Read SQL query from file instead of command line
        \\  --completions <shell>        Generate shell completion script (bash, zsh, fish)
        \\  -h, --help                   Show this help message and exit
        \\  -V, --version                Show version and exit
        \\
        \\HTTP Input:
        \\  -u, --url <url>              Fetch input data from HTTP/HTTPS URL (repeatable)
        \\                               Each URL becomes a table: url0, url1... or use NAME=URL
        \\                               Can combine with file arguments and stdin
        \\  --input-format <fmt>         Override input format for the preceeding --url
        \\                               csv (default), tsv, json, ndjson, xml, yaml, parquet
        \\                               When used before any --url, sets global format for stdin
        \\  --http-header <header>       Custom HTTP header for the preceeding --url (repeatable)
        \\                               Format: "Key: Value". Requests with headers don't follow redirects.
        \\                               Must appear after a --url flag
        \\  --max-body-size <bytes>      Maximum response body size for ALL --url (default: 104857600 = 100MB)
        \\
        \\Exit codes:
        \\  0  Success
        \\  1  Usage error (missing query, bad arguments, network/HTTP errors)
        \\  2  Input parse error
        \\  3  SQL error
        \\
        \\Examples:
        \\  echo 'name,age\nAlice,30' | sql-pipe 'SELECT * FROM t'
        \\  cat data.tsv | sql-pipe --tsv 'SELECT * FROM t'
        \\  cat data.psv | sql-pipe -d '|' 'SELECT * FROM t'
        \\  cat data.csv | sql-pipe 'SELECT region, SUM(revenue) FROM t GROUP BY region'
        \\  sql-pipe orders.csv 'SELECT * FROM orders WHERE amount > 100'
        \\  sql-pipe data.json 'SELECT * FROM data WHERE score > 80'
        \\  sql-pipe -I tsv data.txt 'SELECT * FROM data'
        \\  sql-pipe orders.csv customers.csv 'SELECT c.name, SUM(o.amount) FROM orders o JOIN customers c ON o.cust_id = c.id GROUP BY c.name'
        \\  cat events.csv | sql-pipe users.csv 'SELECT * FROM t JOIN users ON t.uid = users.id'
        \\  cat data.csv | sql-pipe --output-format json 'SELECT * FROM t'
        \\  cat data.json | sql-pipe --input-format json 'SELECT * FROM t'
        \\  cat data.ndjson | sql-pipe -I ndjson -O ndjson 'SELECT name FROM t WHERE age > 18'
        \\  cat data.xml | sql-pipe -I xml --xml-root channel --xml-row item "SELECT title FROM t"
        \\  cat data.csv | sql-pipe --sample 5
        \\  sql-pipe -f query.sql data.csv
        \\  cat data.csv | sql-pipe -f query.sql
        \\
        \\HTTP Examples:
        \\  # Fetch CSV directly from URL
        \\  sql-pipe --url https://example.com/data.csv 'SELECT * FROM url0'
        \\
        \\  # Fetch JSON from API with auto-detection
        \\  sql-pipe --url "https://api.github.com/repos/owner/repo/issues" 'SELECT * FROM url0'
        \\
        \\  # With custom headers (e.g., Authorization)
        \\  sql-pipe --url https://api.example.com/data.json --http-header "Authorization: Bearer token" 'SELECT * FROM url0'
        \\
        \\  # Explicit format override with -I
        \\  sql-pipe --url https://example.com/data --input-format csv 'SELECT * FROM url0'
        \\
        \\  # Multiple URLs with joins
        \\  sql-pipe --url https://api.example.com/users.json --url https://api.example.com/orders.json 'SELECT * FROM url0 JOIN url1 ON url0.id = url1.user_id'
        \\
        \\  # Named URLs for clearer queries
        \\  sql-pipe --url users=https://api.example.com/users.json --url orders=https://api.example.com/orders.json 'SELECT * FROM users JOIN orders ON users.id = orders.user_id'
        \\
        \\  # Combine URL with file arguments (joins)
        \\  sql-pipe --url https://api.example.com/orders.json orders.csv 'SELECT * FROM url0 JOIN orders ON url0.id = orders.id'
        \\
        \\  # Per-URL format and headers
        \\  sql-pipe --url https://api.example.com/data.json --input-format json --http-header "Accept: application/json" --url https://example.com/data.csv 'SELECT * FROM url0 JOIN url1 ON url0.id = url1.id'
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
    var query_file: ?[]const u8 = null;
    var query_file_seen = false;
    var type_inference = true;
    var no_stdin = false;
    var delimiter: []const u8 = ",";
    var header = false;
    var input_format: InputFormat = .csv;
    var input_format_explicit = false;
    var output_format: OutputFormat = .csv;

    var max_rows: ?usize = null;
    var verbose = false;
    var silent = false;
    var output: ?[]const u8 = null;
    var xml_root: []const u8 = "results";
    var xml_row: []const u8 = "row";
    var xml_root_input: ?[]const u8 = null;
    var xml_row_input: ?[]const u8 = null;
    var null_value: ?[]const u8 = null;
    var json_path: ?[]const u8 = null;
    var inspect_mode: ?InspectMode = null;
    var inspect_sample_n: usize = 10;
    var inspect_deprecated = false;
    var repl_mode = false;
    var disk = false;
    var save_path: ?[:0]const u8 = null;
    var explain = false;
    var table_mode: TableMode = .auto;
    var sql_table: []const u8 = "t";
    var html_class: []const u8 = "";
    var seen_dashdash = false;
    var positional_args: std.ArrayList([]const u8) = .empty;
    defer positional_args.deinit(allocator);

    var urls: std.ArrayList(UrlInput) = .empty;
    var current_url_idx: ?usize = null;
    var max_body_size: usize = 100 * 1024 * 1024;
    var max_body_size_set = false;

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
        } else if (std.mem.eql(u8, arg, "--no-stdin")) {
            no_stdin = true;
        } else if (std.mem.eql(u8, arg, "--header") or std.mem.eql(u8, arg, "-H")) {
            header = true;
        } else if (std.mem.eql(u8, arg, "--json")) {
            output_format = .json;
        } else if (std.mem.eql(u8, arg, "-O") or std.mem.eql(u8, arg, "--output-format")) {
            i += 1;
            if (i >= args.len) return error.InvalidOutputFormat;
            output_format = OutputFormat.parse(args[i]) catch return error.InvalidOutputFormat;
        } else if (std.mem.startsWith(u8, arg, "--output-format=")) {
            output_format = OutputFormat.parse(arg["--output-format=".len..]) catch return error.InvalidOutputFormat;
        } else if (std.mem.startsWith(u8, arg, "-O=")) {
            output_format = OutputFormat.parse(arg["-O=".len..]) catch return error.InvalidOutputFormat;
        } else if (std.mem.eql(u8, arg, "--sql-table")) {
            i += 1;
            if (i >= args.len) return error.MissingSqlTableValue;
            sql_table = args[i];
        } else if (std.mem.startsWith(u8, arg, "--sql-table=")) {
            sql_table = arg["--sql-table=".len..];
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
        } else if (std.mem.eql(u8, arg, "--inspect")) {
            i += 1;
            if (i >= args.len) return error.MissingInspectMode;
            const mode = InspectMode.parse(args[i]) catch return error.InvalidInspectMode;
            inspect_mode = mode;
        } else if (std.mem.startsWith(u8, arg, "--inspect=")) {
            const mode = InspectMode.parse(arg["--inspect=".len..]) catch return error.InvalidInspectMode;
            inspect_mode = mode;
        } else if (std.mem.eql(u8, arg, "--columns")) {
            inspect_mode = .columns;
            inspect_deprecated = true;
        } else if (std.mem.eql(u8, arg, "--validate")) {
            inspect_mode = .validate;
            inspect_deprecated = true;
        } else if (std.mem.eql(u8, arg, "--sample")) {
            inspect_mode = .sample;
            inspect_deprecated = true;
            // Peek at next arg: if it is a positive integer, consume it as the sample count
            if (i + 1 < args.len) {
                const next = args[i + 1];
                if (next.len > 0 and next[0] != '-') {
                    if (std.fmt.parseUnsigned(usize, next, 10)) |n| {
                        if (n == 0) return error.InvalidSampleCount;
                        inspect_sample_n = n;
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
            inspect_sample_n = n;
            inspect_mode = .sample;
            inspect_deprecated = true;
        } else if (std.mem.eql(u8, arg, "--stats") or std.mem.eql(u8, arg, "--profile")) {
            inspect_mode = .stats;
            inspect_deprecated = true;
        } else if (std.mem.eql(u8, arg, "--schema")) {
            inspect_mode = .schema;
            inspect_deprecated = true;
        } else if (std.mem.eql(u8, arg, "--repl") or std.mem.eql(u8, arg, "-r")) {
            repl_mode = true;
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
        } else if (std.mem.eql(u8, arg, "--save") or std.mem.eql(u8, arg, "-S")) {
            i += 1;
            if (i >= args.len) return error.InvalidSavePath;
            if (args[i].len == 0) return error.InvalidSavePath;
            save_path = args[i];
        } else if (std.mem.startsWith(u8, arg, "--save=")) {
            const val = arg["--save=".len..];
            if (val.len == 0) return error.InvalidSavePath;
            save_path = val;
        } else if (std.mem.startsWith(u8, arg, "-S=")) {
            const val = arg["-S=".len..];
            if (val.len == 0) return error.InvalidSavePath;
            save_path = val;
        } else if (std.mem.eql(u8, arg, "--explain")) {
            explain = true;
        } else if (std.mem.eql(u8, arg, "--table")) {
            table_mode = .always;
        } else if (std.mem.eql(u8, arg, "--null-value")) {
            i += 1;
            if (i >= args.len) return error.MissingNullValue;
            null_value = args[i];
        } else if (std.mem.startsWith(u8, arg, "--null-value=")) {
            null_value = arg["--null-value=".len..];
        } else if (std.mem.eql(u8, arg, "--html-class")) {
            i += 1;
            if (i >= args.len) return error.MissingHtmlClassValue;
            html_class = args[i];
        } else if (std.mem.startsWith(u8, arg, "--html-class=")) {
            html_class = arg["--html-class=".len..];
        } else if (std.mem.eql(u8, arg, "--no-table")) {
            table_mode = .never;
        } else if (std.mem.eql(u8, arg, "--completions")) {
            i += 1;
            if (i >= args.len) return error.InvalidCompletionsShell;
            const shell = CompletionsShell.parse(args[i]) catch return error.InvalidCompletionsShell;
            return .{ .completions = CompletionsArgs{ .shell = shell } };
        } else if (std.mem.startsWith(u8, arg, "--completions=")) {
            const shell = CompletionsShell.parse(arg["--completions=".len..]) catch return error.InvalidCompletionsShell;
            return .{ .completions = CompletionsArgs{ .shell = shell } };
        } else if (std.mem.eql(u8, arg, "-f") or std.mem.eql(u8, arg, "--file")) {
            i += 1;
            if (i >= args.len) return error.InvalidQueryFile;
            if (args[i].len == 0) return error.InvalidQueryFile;
            if (query_file_seen) return error.MultipleQueryFiles;
            query_file_seen = true;
            query_file = args[i];
        } else if (std.mem.startsWith(u8, arg, "--file=")) {
            if (query_file_seen) return error.MultipleQueryFiles;
            query_file_seen = true;
            query_file = arg["--file=".len..];
            if (query_file.?.len == 0) return error.InvalidQueryFile;
        } else if (std.mem.startsWith(u8, arg, "-f=")) {
            if (query_file_seen) return error.MultipleQueryFiles;
            query_file_seen = true;
            query_file = arg["-f=".len..];
            if (query_file.?.len == 0) return error.InvalidQueryFile;
        } else if (std.mem.eql(u8, arg, "--url") or std.mem.eql(u8, arg, "-u")) {
            i += 1;
            if (i >= args.len) return error.InvalidUrl;
            if (args[i].len == 0) return error.InvalidUrl;
            const url_val = args[i];
            // Check for NAME=URL syntax
            const eq_pos = std.mem.indexOfScalar(u8, url_val, '=');
            if (eq_pos) |pos| {
                if (pos > 0) {
                    const name = url_val[0..pos];
                    const url = url_val[pos + 1..];
                    if (url.len == 0) return error.InvalidUrl;
                    try urls.append(allocator, .{
                        .url = url,
                        .table_name = name,
                        .format = null,
                        .headers = &.{},
                    });
                } else {
                    try urls.append(allocator, .{
                        .url = url_val,
                        .table_name = null,
                        .format = null,
                        .headers = &.{},
                    });
                }
            } else {
                try urls.append(allocator, .{
                    .url = url_val,
                    .table_name = null,
                    .format = null,
                    .headers = &.{},
                });
            }
            current_url_idx = urls.items.len - 1;
        } else if (std.mem.startsWith(u8, arg, "--url=")) {
            const val = arg["--url=".len..];
            if (val.len == 0) return error.InvalidUrl;
            const eq_pos = std.mem.indexOfScalar(u8, val, '=');
            if (eq_pos) |pos| {
                if (pos > 0) {
                    const name = val[0..pos];
                    const url = val[pos + 1..];
                    if (url.len == 0) return error.InvalidUrl;
                    try urls.append(allocator, .{
                        .url = url,
                        .table_name = name,
                        .format = null,
                        .headers = &.{},
                    });
                } else {
                    try urls.append(allocator, .{
                        .url = val,
                        .table_name = null,
                        .format = null,
                        .headers = &.{},
                    });
                }
            } else {
                try urls.append(allocator, .{
                    .url = val,
                    .table_name = null,
                    .format = null,
                    .headers = &.{},
                });
            }
            current_url_idx = urls.items.len - 1;
        } else if (std.mem.startsWith(u8, arg, "-u=")) {
            const val = arg["-u=".len..];
            if (val.len == 0) return error.InvalidUrl;
            const eq_pos = std.mem.indexOfScalar(u8, val, '=');
            if (eq_pos) |pos| {
                if (pos > 0) {
                    const name = val[0..pos];
                    const url = val[pos + 1..];
                    if (url.len == 0) return error.InvalidUrl;
                    try urls.append(allocator, .{
                        .url = url,
                        .table_name = name,
                        .format = null,
                        .headers = &.{},
                    });
                } else {
                    try urls.append(allocator, .{
                        .url = val,
                        .table_name = null,
                        .format = null,
                        .headers = &.{},
                    });
                }
            } else {
                try urls.append(allocator, .{
                    .url = val,
                    .table_name = null,
                    .format = null,
                    .headers = &.{},
                });
            }
            current_url_idx = urls.items.len - 1;
        } else if (std.mem.eql(u8, arg, "--input-format") or std.mem.eql(u8, arg, "-I")) {
            i += 1;
            if (i >= args.len) return error.InvalidInputFormat;
            const fmt = InputFormat.parse(args[i]) catch return error.InvalidInputFormat;
            if (current_url_idx) |idx| {
                urls.items[idx].format = fmt;
            } else {
                input_format = fmt;
                input_format_explicit = true;
            }
        } else if (std.mem.startsWith(u8, arg, "--input-format=")) {
            const fmt = InputFormat.parse(arg["--input-format=".len..]) catch return error.InvalidInputFormat;
            if (current_url_idx) |idx| {
                urls.items[idx].format = fmt;
            } else {
                input_format = fmt;
                input_format_explicit = true;
            }
        } else if (std.mem.startsWith(u8, arg, "-I=")) {
            const fmt = InputFormat.parse(arg["-I=".len..]) catch return error.InvalidInputFormat;
            if (current_url_idx) |idx| {
                urls.items[idx].format = fmt;
            } else {
                input_format = fmt;
                input_format_explicit = true;
            }
        } else if (std.mem.eql(u8, arg, "--http-header")) {
            i += 1;
            if (i >= args.len or !isValidHttpHeader(args[i])) return error.InvalidHttpHeader;
            if (current_url_idx) |idx| {
                var headers: std.ArrayList([]const u8) = .empty;
                for (urls.items[idx].headers) |h| try headers.append(allocator, h);
                try headers.append(allocator, args[i]);
                urls.items[idx].headers = headers.items;
            } else {
                return error.UrlHeaderRequiresUrl;
            }
        } else if (std.mem.startsWith(u8, arg, "--http-header=")) {
            const val = arg["--http-header=".len..];
            if (!isValidHttpHeader(val)) return error.InvalidHttpHeader;
            if (current_url_idx) |idx| {
                var headers: std.ArrayList([]const u8) = .empty;
                for (urls.items[idx].headers) |h| try headers.append(allocator, h);
                try headers.append(allocator, val);
                urls.items[idx].headers = headers.items;
            } else {
                return error.UrlHeaderRequiresUrl;
            }
        } else if (std.mem.eql(u8, arg, "--max-body-size")) {
            i += 1;
            if (i >= args.len) return error.InvalidMaxBodySize;
            max_body_size = std.fmt.parseUnsigned(usize, args[i], 10) catch return error.InvalidMaxBodySize;
            if (max_body_size == 0) return error.InvalidMaxBodySize;
            max_body_size_set = true;
        } else if (std.mem.startsWith(u8, arg, "--max-body-size=")) {
            max_body_size = std.fmt.parseUnsigned(usize, arg["--max-body-size=".len..], 10) catch return error.InvalidMaxBodySize;
            if (max_body_size == 0) return error.InvalidMaxBodySize;
            max_body_size_set = true;
        } else {
            try positional_args.append(allocator, arg);
        }
    }

    // ─── Convert positional args to files + query ──────────────────────────
    const pos = positional_args.items;
    const is_special_mode = inspect_mode != null or repl_mode;

    // Build file list from positional args
    var files: std.ArrayList(FileInput) = .empty;

    if (pos.len > 0) {
        if (is_special_mode or query_file != null) {
            // Special modes or -f: every positional arg is a file input
            for (pos) |p| {
                const name = try tableNameFromPath(allocator, p);
                const fmt = if (input_format_explicit) input_format else (InputFormat.fromExtension(p) orelse input_format);
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
                const fmt = if (input_format_explicit) input_format else (InputFormat.fromExtension(p) orelse input_format);
                try files.append(allocator, .{
                    .path = p,
                    .table_name = name,
                    .format = fmt,
                });
            }
        }
    }

    // Effective input format: per-file auto-detection when a file is present,
    // else the global default (CSV) or explicit -I value.
    const effective_input_format: InputFormat = if (files.items.len > 0)
        (if (input_format_explicit) input_format else files.items[0].format)
    else
        input_format;

    // Check for duplicate table names (would cause conflicting table definitions)
    {
        var seen = std.StringHashMap(void).init(allocator);
        defer seen.deinit();
        for (files.items) |f| {
            const gop = try seen.getOrPut(f.table_name);
            if (gop.found_existing) return error.DuplicateTableName;
        }
    }

    // Non-CSV/TSV/HTML output format is mutually exclusive with --header
    if (output_format != .csv and output_format != .tsv and output_format != .html and header)
        return error.IncompatibleFlags;

    // --inspect is mutually exclusive with query, output, and explain
    if (inspect_mode != null and (query != null or query_file != null))
        return error.InspectWithQuery;
    if (inspect_mode != null and output != null)
        return error.InspectWithOutput;
    if (inspect_mode != null and explain)
        return error.InspectWithExplain;

    // --explain is mutually exclusive with --output (even outside inspect mode)
    if (explain and output != null)
        return error.ExplainWithOutput;

    // --inspect sample is incompatible with JSON output format
    if (inspect_mode == .sample and (output_format == .json or output_format == .ndjson))
        return error.InspectSampleWithJson;

    // --save is incompatible with special modes
    if (save_path != null and inspect_mode != null)
        return error.SaveIncompatibleMode;

    // --save implies disk-backed behavior; both together is redundant
    if (save_path != null and disk)
        return error.SaveIncompatibleDisk;

    // --silent and --verbose are mutually exclusive
    if (silent and verbose)
        return error.SilentVerboseConflict;

    // --xml-root and --xml-row must be valid XML element names (only validated in XML mode)
    if (effective_input_format == .xml or output_format == .xml) {
        if (!isValidXmlName(xml_root) or !isValidXmlName(xml_row))
            return error.InvalidXmlName;
    }

    // --json-path requires JSON input (the flag only applies to JSON object navigation)
    if (json_path != null and effective_input_format != .json)
        return error.JsonPathRequiresJson;

    // --table requires CSV or TSV output format (table formatting is visual only)
    if (table_mode == .always and output_format != .csv and output_format != .tsv)
        return error.TableWithNonCsv;

    // URL validation: columns, validate, sample inspect modes don't support URL input
    if (urls.items.len > 0 and inspect_mode != null) {
        const is_url_compat = switch (inspect_mode.?) {
            .stats, .schema => true,
            .columns, .validate, .sample => false,
        };
        if (!is_url_compat) return error.UrlIncompatibleMode;
    }
    if (urls.items.len == 0 and max_body_size_set)
        return error.HttpFlagsRequireUrl;

    // Check for duplicate table names across URLs, files, and stdin
    {
        var seen = std.StringHashMap(void).init(allocator);
        defer seen.deinit();
        for (files.items) |f| {
            const gop = try seen.getOrPut(f.table_name);
            if (gop.found_existing) return error.DuplicateTableName;
        }
        for (urls.items, 0..) |url_input, url_idx| {
            const table_name = url_input.table_name orelse blk: {
                var buf: [16]u8 = undefined;
                const written = std.fmt.bufPrint(&buf, "url{}", .{url_idx}) catch unreachable;
                break :blk allocator.dupeZ(u8, written) catch unreachable;
            };
            const gop = try seen.getOrPut(table_name);
            if (gop.found_existing) return error.DuplicateUrlTableName;
        }
        // Check stdin table name
        const stdin_table = if (urls.items.len > 0 or files.items.len > 0) "stdin" else "t";
        const gop = try seen.getOrPut(stdin_table);
        if (gop.found_existing) return error.DuplicateTableName;
    }

    // --inspect mode: dispatch to the appropriate inspect sub-mode
    if (inspect_mode) |mode| {
        return .{ .inspect = ParsedArgs{
            .query = "",
            .files = files.items,
            .urls = urls.items,
            .type_inference = type_inference,
            .no_stdin = no_stdin,
            .delimiter = delimiter,
            .header = header,
            .input_format = effective_input_format,
            .input_format_explicit = input_format_explicit,
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
            .save_path = save_path,
            .explain = explain,
            .table_mode = table_mode,
            .sql_table = sql_table,
            .html_class = html_class,
            .null_value = null_value,
            .max_body_size = max_body_size,
            .inspect_args = InspectArgs{ .mode = mode, .sample_n = inspect_sample_n, .deprecated = inspect_deprecated },
            .sample_n = inspect_sample_n,
        } };
    }

    // --repl validation: reject incompatible flags
    if (repl_mode) {
        if (inspect_mode != null) {
            return error.ReplIncompatibleMode;
        }
        if (query_file != null) {
            return error.ReplWithQueryFile;
        }
        if (output != null) {
            return error.ReplWithOutput;
        }
        if (explain) {
            return error.ReplIncompatibleExplain;
        }
    }

    // When --repl is set, no query is needed (REPL reads queries interactively).
    const resolved_query: []const u8 = if (repl_mode)
        (query orelse "")
    else
        query orelse (if (query_file != null) "" else return error.MissingQuery);

    const parsed_args: ParsedArgs = .{
        .query = resolved_query,
        .query_file = query_file,
        .files = files.items,
        .urls = urls.items,
        .type_inference = type_inference,
        .no_stdin = no_stdin,
        .delimiter = delimiter,
        .header = header,
        .input_format = input_format,
        .input_format_explicit = input_format_explicit,
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
        .save_path = save_path,
        .explain = explain,
        .table_mode = table_mode,
        .sql_table = sql_table,
        .html_class = html_class,
        .null_value = null_value,
        .max_body_size = max_body_size,
    };

    if (repl_mode) {
        return .{ .repl = parsed_args };
    } else {
        return .{ .parsed = parsed_args };
    }
}

fn isValidHttpHeader(header: []const u8) bool {
    const colon = std.mem.indexOfScalar(u8, header, ':') orelse return false;
    return std.mem.trim(u8, header[0..colon], " \t").len > 0;
}

/// Derive a table name from a file path (basename without extension).
fn tableNameFromPath(allocator: std.mem.Allocator, path: []const u8) (std.mem.Allocator.Error)![]const u8 {
    const stem = std.fs.path.stem(path);
    return allocator.dupe(u8, stem);
}
