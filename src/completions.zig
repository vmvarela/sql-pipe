const std = @import("std");
const args = @import("args.zig");

const CompletionsShell = args.CompletionsShell;

pub fn generateCompletions(shell: CompletionsShell, writer: *std.Io.Writer) !void {
    switch (shell) {
        .bash => try generateBash(writer),
        .zsh => try generateZsh(writer),
        .fish => try generateFish(writer),
    }
}

fn generateBash(writer: *std.Io.Writer) !void {
    try writer.writeAll(
        \\_sql-pipe() {
        \\  local cur prev words cword
        \\  _init_completion -s || return
        \\
        \\  case $prev in
        \\    -d|--delimiter)
        \\      return
        \\      ;;
        \\    -I|--input-format)
        \\      COMPREPLY=($(compgen -W "csv tsv json ndjson yaml xml" -- "$cur"))
        \\      return
        \\      ;;
        \\    -O|--output-format)
        \\      COMPREPLY=($(compgen -W "csv tsv json ndjson xml markdown md html sql" -- "$cur"))
        \\      return
        \\      ;;
        \\    --completions)
        \\      COMPREPLY=($(compgen -W "bash zsh fish" -- "$cur"))
        \\      return
        \\      ;;
        \\    -u|--url|--http-header|--max-body-size|--max-rows|--sql-table|--null-value|--html-class|--output|--xml-root|--xml-row|--json-path)
        \\      return
        \\      ;;
        \\    -S|--save)
        \\      _filedir
        \\      return
        \\      ;;
        \\    --sample)
        \\      COMPREPLY=($(compgen -W "1 5 10 25 50 100 500 1000" -- "$cur"))
        \\      return
        \\      ;;
        \\    -f|--file)
        \\      _filedir
        \\      return
        \\      ;;
        \\  esac
        \\
        \\  if [[ "$cur" == -* ]]; then
        \\    COMPREPLY=($(compgen -W '
        \\      --delimiter -d
        \\      --tsv
        \\      --input-format -I
        \\      --output-format -O
        \\      --json
        \\      --sql-table
        \\      --no-type-inference
        \\      --no-stdin
        \\      --header -H
        \\      --max-rows
        \\      --url -u
        \\      --http-header
        \\      --max-body-size
        \\      --verbose -v
        \\      --silent -s
        \\      --validate
        \\      --columns
        \\      --sample
        \\      --stats --profile
        \\      --schema
        \\      --output
        \\      --xml-root
        \\      --xml-row
        \\      --json-path
        \\      --disk
        \\      --save -S
        \\      --explain
        \\      --repl -r
        \\      --table --no-table
        \\      --null-value
        \\      --html-class
        \\      --completions
        \\      --file -f
        \\      --help -h
        \\      --version -V
        \\    ' -- "$cur"))
        \\  else
        \\    _filedir
        \\  fi
        \\}
        \\complete -F _sql-pipe sql-pipe
        \\
    );
}

fn generateZsh(writer: *std.Io.Writer) !void {
    try writer.writeAll(
        \\#compdef sql-pipe
        \\
        \\_sql-pipe() {
        \\  local -a opts
        \\  opts=(
        \\    '(-d --delimiter)'{-d+,--delimiter=}'[Input field delimiter]:delimiter:'
        \\    '--tsv[Tab-separated input alias]'
        \\    '(-I --input-format)'{-I+,--input-format=}'[Input format]:format:(csv tsv json ndjson yaml xml)'
        \\    '(-O --output-format)'{-O+,--output-format=}'[Output format]:format:(csv tsv json ndjson xml markdown html sql)'
        \\    '--json[Alias for --output-format json]'
        \\    '--sql-table=[SQL INSERT table name]:table name:'
        \\    '--no-type-inference[Treat all columns as TEXT]'
        \\    '--no-stdin[Do not read from stdin]'
        \\    '(-H --header)'{-H,--header}'[Print column names as first output row]'
        \\    '--max-rows=[Row limit]:rows:'
        \\    '(-u --url)'{-u+,--url=}'[Fetch HTTP/HTTPS input into table t]:URL:'
        \\    '*--http-header=[HTTP request header for --url]:header:'
        \\    '--max-body-size=[Maximum --url response body size]:bytes:'
        \\    '(-v --verbose)'{-v,--verbose}'[Force row count to stderr]'
        \\    '(-s --silent)'{-s,--silent}'[Suppress row count output]'
        \\    '--validate[Parse input and print summary]'
        \\    '--columns[List column names]'
        \\    '--sample::Number of rows:(1 5 10 25 50 100 500 1000)'
        \\    '--stats[Compute per-column statistics]'
        \\    '--profile[Alias for --stats]'
        \\    '--schema[Print inferred CREATE TABLE DDL]'
        \\    '--output=[Write results to file]:file:_files'
        \\    '--xml-root=[Root element name]:name:'
        \\    '--xml-row=[Row element name]:name:'
        \\    '--json-path=[Path to JSON array]:path:'
        \\    '--disk[Use file-backed temp database]'
        \\    '(-S --save)'{-S+,--save=}'[Persist DB to file]:file:_files'
        \\    '--explain[Print query plan to stderr]'
        \\    '(-r --repl)'{-r,--repl}'[Enter interactive REPL mode]'
        \\    '--table[Force table output]'
        \\    '--no-table[Force CSV output]'
        \\    '--null-value=[Custom NULL representation]:string:'
        \\    '--html-class=[HTML table CSS class]:class:'
        \\    '--completions=[Generate shell completions]:shell:(bash zsh fish)'
        \\    '(-f --file)'{-f+,--file=}'[Read SQL query from file]:file:_files'
        \\    '(-h --help)'{-h,--help}'[Show help message]'
        \\    '(-V --version)'{-V,--version}'[Show version]'
        \\    '*:file:_files'
        \\  )
        \\  _arguments $opts
        \\}
        \\
        \\_sql-pipe
        \\
    );
}

fn generateFish(writer: *std.Io.Writer) !void {
    try writer.writeAll(
        \\complete -c sql-pipe -f
        \\
        \\# Input options
        \\complete -c sql-pipe -s d -l delimiter -r -d "Input field delimiter"
        \\complete -c sql-pipe -l tsv -d "Alias for --delimiter \\'\\\\t\\'"
        \\complete -c sql-pipe -s I -l input-format -r -f -a "csv tsv json ndjson yaml xml" -d "Input format"
        \\complete -c sql-pipe -s O -l output-format -r -f -a "csv tsv json ndjson xml markdown html sql" -d "Output format"
        \\complete -c sql-pipe -l json -d "Alias for --output-format json"
        \\
        \\# Query options
        \\complete -c sql-pipe -l sql-table -r -d "Target table for SQL INSERT"
\\complete -c sql-pipe -l no-type-inference -d "Treat all columns as TEXT"
\\complete -c sql-pipe -l no-stdin -d "Do not read from stdin"
\\complete -c sql-pipe -s H -l header -d "Print column names as first output row"
        \\complete -c sql-pipe -l max-rows -r -d "Stop if more than N data rows read"
        \\complete -c sql-pipe -s u -l url -r -d "Fetch HTTP/HTTPS input into table t"
        \\complete -c sql-pipe -l http-header -r -d "HTTP request header for --url"
        \\complete -c sql-pipe -l max-body-size -r -d "Maximum --url response body size"
        \\complete -c sql-pipe -s v -l verbose -d "Force row count to stderr"
        \\complete -c sql-pipe -s s -l silent -d "Suppress row count output"
        \\complete -c sql-pipe -l validate -d "Parse input and print summary"
        \\complete -c sql-pipe -l columns -d "List column names and exit"
        \\complete -c sql-pipe -l sample -r -f -a "1 5 10 25 50 100 500 1000" -d "Print schema and sample rows"
        \\complete -c sql-pipe -l stats -d "Compute per-column statistics"
        \\complete -c sql-pipe -l profile -d "Alias for --stats"
        \\complete -c sql-pipe -l schema -d "Print inferred CREATE TABLE DDL"
        \\
        \\# Output options
        \\complete -c sql-pipe -l output -r -d "Write results to file"
        \\complete -c sql-pipe -l xml-root -r -d "Root element name for XML"
        \\complete -c sql-pipe -l xml-row -r -d "Row element name for XML"
        \\complete -c sql-pipe -l json-path -r -d "Path to JSON array"
        \\complete -c sql-pipe -l disk -d "Use file-backed temp database"
        \\complete -c sql-pipe -s S -l save -r -d "Use file as SQLite DB (persisted)"
        \\complete -c sql-pipe -l explain -d "Print query plan to stderr"
        \\complete -c sql-pipe -s r -l repl -d "Enter interactive REPL mode"
        \\complete -c sql-pipe -l table -d "Force pretty-printed table output"
        \\complete -c sql-pipe -l no-table -d "Force CSV output"
        \\complete -c sql-pipe -l null-value -r -d "Custom NULL representation"
        \\complete -c sql-pipe -l html-class -r -d "CSS class for HTML table"
        \\
        \\# Meta options
        \\complete -c sql-pipe -l completions -r -f -a "bash zsh fish" -d "Generate shell completions"
        \\complete -c sql-pipe -s f -l file -r -d "Read SQL query from file"
        \\complete -c sql-pipe -s h -l help -d "Show help message"
        \\complete -c sql-pipe -s V -l version -d "Show version"
        \\
    );
}
