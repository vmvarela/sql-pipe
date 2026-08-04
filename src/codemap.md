# src/

## Responsibility

CLI tool that pipes structured data (CSV, TSV, JSON, NDJSON, XML, YAML, Parquet) through an embedded SQLite engine. Accepts piped stdin, file arguments, and HTTP(S) URLs as input sources. Loads each source into a named in-memory (or disk-backed) SQLite table, runs a user-supplied SQL query, and emits results in one of eight output formats (CSV, TSV, JSON, NDJSON, XML, Markdown, HTML, SQL). Also provides ancillary modes for column listing, validation, sampling, statistics, and schema DDL generation — plus shell completion scripts for bash/zsh/fish.

## Module Overview

| File | Role |
|---|---|
| `main.zig` | Entry point, top-level orchestration of load-query-output pipeline |
| `args.zig` | CLI argument parser, error types, struct definitions for all modes |
| `format.zig` | Input/Output format enums, `OutputWriter` dispatcher, CSV write helpers |
| `sqlite.zig` | Shared SQLite wrappers (create table, prepare insert, transactions, error helpers) |
| `csv.zig` | RFC 4180 streaming CSV parser (state machine, multi-char delimiters) |
| `loader.zig` | CSV/TSV loader with type inference (INTEGER, REAL, DATE, DATETIME variants) |
| `json.zig` | JSON array + NDJSON input loading, JSON/NDJSON output formatting |
| `xml.zig` | Custom row-based XML parser, XML output formatting (header/row/footer) |
| `yaml.zig` | YAML sequence-of-mappings input loader via libyaml FFI |
| `parquet.zig` | Parquet columnar input loader via zig-parquet DynamicReader API (physical + logical type mapping, batch insert) |
| `table.zig` | Pretty-printed table (box-drawing) — two-pass streaming, O(cols) memory |
| `markdown.zig` | Markdown table output — two-pass streaming, O(cols) memory |
| `visual.zig` | UTF-8 display-width helpers (CJK width 2, emoji width 2) |
| `http.zig` | HTTP(S) URL fetching with content-type and extension format detection |
| `completions.zig` | Shell completion generation (bash `complete`, zsh `_arguments`, fish `complete`) |

## Design Patterns

**Pipeline architecture.** Data flows through three stages: load → query → output. All input formats parse into SQLite tables; all output formats read from SQLite result sets. The pipeline processes each input source independently (URL first, then file arguments, then stdin), inserting into separate named tables before the single user query runs.

**OutputWriter dispatcher.** `format.zig` defines an `OutputWriter` struct with `begin()` / `writeRow()` / `end()` lifecycle. A single dispatch point in `execQuery()` selects format-specific writers (JSON, NDJSON, CSV, TSV, XML, SQL, HTML). Markdown and table are handled as special cases before the generic path (they require two-pass streaming over all rows).

**Two-pass streaming for formatted tables.** Both `table.zig` and `markdown.zig` use an identical two-pass pattern: first pass steps through all rows to measure column widths and detect numeric columns (via SQLite column type, not string parsing); second pass resets the statement and writes header/separator/rows. Memory is `O(cols)` — rows are never buffered.

**CSV state machine.** `csv.zig` implements a 4-state automaton (`field_start`, `unquoted`, `quoted`, `quote_saw`) over a byte-level reader. Supports RFC 4180 including multi-char delimiters (up to 8 bytes) with greedy left-to-right partial matching. Zero intermediate buffering — each byte processed exactly once.

**Event-driven XML parser.** `xml.zig` contains a hand-written, row-oriented XML parser (`XmlParser`) with line/column error reporting. Skips prologue (declaration, comments, PIs), navigates to a configurable container element, and iterates row elements via `nextRow()`. Entity decoding for the 5 predefined XML entities plus numeric character references (decimal and hex). Nested elements in column content are preserved as raw XML substrings.

**Type inference ladder.** `loader.zig` infers SQLite column types from CSV data using a priority ladder: DATETIME > DATE > INTEGER > REAL > TEXT. Slash-format date disambiguation (DD/MM vs MM/DD) uses a per-column voting system. Leading-zero integers like `"007"` are demoted to TEXT to prevent lossy numeric coercion.

**Comptime enum reflection.** Both `InputFormat` and `OutputFormat` use `std.meta.stringToEnum` for parsing and `std.fs.path.extension` combined with `stringToEnum` for file extension auto-detection. Zig's comptime reflection eliminates manual switch/match tables for format names.

**Pure Zig columnar loader.** `parquet.zig` reads the entire input into a memory buffer, validates the `PAR1` magic header, then hands it to the zig-parquet DynamicReader (`openBufferDynamic`). Column metadata comes from walking the schema tree: physical types (BOOLEAN/INT32/INT64/FLOAT/DOUBLE/BYTE_ARRAY/FIXED_LEN_BYTE_ARRAY/INT96) map to SQLite INTEGER/REAL/TEXT via `physicalToAffinity()`, with logical types (DATE, TIME, TIMESTAMP, DECIMAL) overriding to TEXT (or INTEGER for scale-0 DECIMAL). Rows are inserted in batches per row group via `readAllRows()`, with logical-type values converted to ISO text (epoch-day/seconds/millis → `YYYY-MM-DD HH:MM:SS`, decimal → text with scale). `loadParquetInput` shares the loaders' pattern of `defer`-freeing accumulated column metadata arrays. Note: `completions.zig` shell-completion word lists for `--input-format` were not extended to include parquet.

**Arena + defer memory management.** Functions like `writeTable` and `writeMarkdown` use arena allocators with `defer arena.deinit()`. The `run()` function in `main.zig` uses a per-function arena for args and defers cleanup. The XML parser's `Column` struct owns its value with explicit `defer` cleanup at every call site. YAML input uses a block of `defer` statements to free accumulated key/value lists.

## Data & Control Flow

```
CLI args → parseArgs() → ArgsResult (tagged union)
                              │
                ┌─────────────┼──────────────┐
                │ parsed      │ help/version  │ special modes
                │             │ (print+exit)  │ (columns/validate/
                │             │               │  sample/stats/schema)
                │             │               │
           run() ├────── url? ──► http.zig:fetchUrl()
                │              │    detectFormatFromContentType()
                │              │    detectFormatFromUrl()
                │              │
                │──── files ──► loadInput() per file
                │  stdin?      │    dispatch on InputFormat:
                │              │      csv/tsv → loader.zig:loadCsvInput()
                │              │               csv.zig parser → type inference → SQLite
                │              │      json   → json.zig:loadJsonArray()
                │              │               parse → first object keys = columns → SQLite
                │              │      ndjson → json.zig:loadNdjsonInput()
                │              │      xml    → xml.zig:loadXmlInput()
                │              │               custom XmlParser → first row columns → SQLite
                │              │      yaml   → yaml.zig:loadYamlInput()
                │              │               libyaml event parser → first mapping keys = cols → SQLite
                │              │      parquet→ parquet.zig:loadParquetInput()
                │              │               read-all-into-buffer → zig-parquet DynamicReader → SQLite
                │              │               physical+logical type map → batch insert (per row group)
                │              │
                │──── execQuery()
                │     │   sqlite3_prepare_v2 → sqlite3_step loop
                │     │   dispatch on OutputFormat:
                │     │     csv/tsv  → format.zig:csvPrintRow
                │     │     json     → json.zig:printJsonRow
                │     │     ndjson   → json.zig:printNdjsonRow
                │     │     xml      → xml.zig:writeXmlRow
                │     │     html     → format.zig:writeHtmlRow
                │     │     sql      → format.zig:writeSqlRow
                │     │     markdown → markdown.zig:writeMarkdown (two-pass)
                │     │     table    → table.zig:writeTable (two-pass)
                │
                stdout_writer / output file / stderr progress
```

**Exit codes:** 0 = success, 1 = usage error, 2 = parse error, 3 = SQL error.

**Error handling pattern:** Format-specific loaders call `sqlite.zig:fatal()` (writes `"error: ..."` to stderr then `std.process.exit`). SQL errors additionally call `fatalSqlWithContext()` which prints the SQLite error message, lists table columns, and offers Levenshtein-based column name suggestions.

## Integration Points

### External C dependencies (FFI)
- **SQLite3** (`c` module) — `sqlite3_open`, `sqlite3_prepare_v2`, `sqlite3_step`, `sqlite3_column_*`, `sqlite3_bind_*`, `sqlite3_exec`, etc. Used by every loader and the query executor.
- **libyaml** (`yaml` module) — `yaml_parser_initialize`, `yaml_parser_set_input_string`, `yaml_parser_parse`, `yaml_event_t`, etc. Used exclusively by `yaml.zig`.
- **Zig stdlib** — `std.http.Client` for HTTP requests (`http.zig`).

### Import graph
```
main.zig
  ├── args.zig        ── standalone (depends on format.zig)
  ├── format.zig      ── standalone (depends on json.zig, xml.zig for OutputWriter)
  ├── sqlite.zig      ── standalone (depends on args.zig for ExitCode)
  ├── loader.zig      ── depends on csv.zig, sqlite.zig
  ├── csv.zig         ── standalone
  ├── json.zig        ── depends on sqlite.zig
  ├── xml.zig         ── depends on sqlite.zig
  ├── yaml.zig        ── depends on sqlite.zig
  ├── parquet.zig     ── depends on sqlite.zig, zig_parquet (DynamicReader)
  ├── http.zig        ── depends on format.zig
  ├── table.zig       ── depends on sqlite.zig, visual.zig
  ├── markdown.zig    ── depends on sqlite.zig, visual.zig
  ├── visual.zig      ── standalone
  ├── completions.zig ── depends on args.zig (CompletionsShell enum)
  └── modes/          ── columns, validate, sample, stats, schema
                       (columns/validate/stats/schema also import parquet.zig
                        to load column metadata via a temp SQLite DB)
```

### Build integration
- `build_options` provides `VERSION` string via build system.
- `c` module provides C API declarations (generated or hand-written Zig bindings for sqlite3 and libyaml).
- `yaml` module provides Zig bindings for libyaml (separate from `c`).
- `zig_parquet` module provides pure Zig Parquet reader (zig-parquet library).

### Consumed by
- `src/modes/` — columns, validate, sample, stats, and schema modes all consume `args.zig` types, `format.zig` enums, and share `sqlite.zig` helpers and format-specific loaders.
- The `build.zig` file at project root.
- Test runner discovers `test` blocks in `csv.zig`, `loader.zig`, `xml.zig`, `visual.zig`, `table.zig`.
