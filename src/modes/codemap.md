# src/modes/

## Responsibility

Implements CLI subcommand "mode" operations — single-purpose commands (`--columns`, `--validate`, `--sample`, `--schema`, `--stats`) that inspect or validate structured data input without running an arbitrary SQL query. Each mode shares the same input-source handling (file or stdin), format dispatch (CSV/TSV/JSON/NDJSON/XML/YAML), and error-reporting patterns as the main pipeline, but produces a specific output (column names, validation summary, sample rows, DDL, per-column statistics).

## Module Overview

| File | Role |
|---|---|
| `source.zig` | Shared helper: `SourceFile` struct + `openInput()` to open a file path or stdin uniformly. Used by all modes. |
| `columns.zig` | `runColumns()` — print column names (and optionally inferred types) from header of first row. |
| `validate.zig` | `runValidate()` — parse input, count rows/columns, detect mismatched column counts, optionally infer types. |
| `sample.zig` | `runSample()` — print schema to stderr + first N data rows to stdout (CSV/TSV only). |
| `schema.zig` | `runSchema()` — load data into an in-memory SQLite table, then print its `CREATE TABLE` DDL. |
| `stats.zig` | `runStats()` — load data into SQLite, then compute per-column stats (type, non-null count, min/max/mean) and render as a table. |

## Design Patterns

- **Uniform function signature**: Every `run*` function takes `(allocator, io, args, stderr_writer, stdout_writer)` — same convention as the main query path in `main.zig`.
- **Input-source abstraction (`source.zig`)**: Modes use `source.openInput(io, input_source, stderr_writer)` returning a `SourceFile` with a `needs_close` flag. This avoids duplicating the file-vs-stdin branching in every mode.
- **Format dispatch via switch**: Each mode matches on `args.input_format` (`.csv`, `.tsv`, `.json`, `.ndjson`, `.xml`, `.yaml`) and calls the appropriate parser module. JSON/NDJSON branches read the full input into memory; CSV/TSV branches stream via `csvReaderWithDelimiter`; YAML loads into a temporary SQLite database via `yaml_mod.loadYamlInput`; XML uses `xml_mod.getXmlColumnNames` or `xml_mod.summarizeXml`.
- **Two-phase architecture (schema + stats modes)**: `schema.zig` and `stats.zig` load data into an in-memory SQLite database first, then query `sqlite_master` or run aggregate SQL to produce output. This reuses the same `loadCsvInput`/`loadJsonArray`/etc. functions from the main pipeline.
- **Streaming (columns + validate + sample modes)**: `columns.zig`, `validate.zig`, and `sample.zig` process CSV/TSV data incrementally with a row buffer capped at `inference_buffer_size` for type inference, then stream remaining rows for counting.
- **Type inference**: Modes that support it (`columns --verbose`, `validate`, `sample`) use `loader.inferTypes()` on a buffered subset of rows. When `type_inference` is disabled, all columns default to `TEXT`.
- **Error handling**: All modes use the shared `fatal()` function from `sqlite.zig` to print a structured error to stderr and exit with the appropriate `ExitCode`.
- **Printer convention**: `columns.zig` and `validate.zig` write directly to stdout/stderr with `writer.print`. `schema.zig` prints raw DDL. `stats.zig` routes output through `table.writeTable()`. `sample.zig` splits output: schema (`#`-prefixed comments) to stderr, data rows to stdout.

## Data & Control Flow

```
main.zig
  └─ parseArgs() -> ArgsResult
       ├─ .columns  -> columns_mode.runColumns()
       ├─ .validate -> validate_mode.runValidate()
       ├─ .sample   -> sample_mode.runSample()
       ├─ .schema   -> schema_mode.runSchema()
       ├─ .stats    -> stats_mode.runStats()
       └─ .parsed   -> main query path (not in modes/)
```

Each mode function:

1. Determines input source: `args.files[0]` path, or stdin if no files.
2. Calls `source.openInput(io, input_source, stderr_writer)` -> `SourceFile`.
3. Dispatches on `args.input_format` to the appropriate parser.
4. Processes data and writes output to stdout/stderr.
5. Cleans up (closes file if not stdin, frees allocated memory).

### Per-mode data flow details

**columns**: Read header row -> parse column names -> optionally buffer N rows for type inference -> print `column_name [TYPE]` lines.

**validate**: Read header -> parse columns -> buffer up to `inference_buffer_size` rows -> optionally infer types -> stream remaining rows counting mismatches -> print `OK: <count> rows, <N> columns (<col TYPE, ...>)`.

**sample**: CSV/TSV only. Read header -> parse columns -> buffer `max(inference_buffer_size, args.n)` rows -> optionally infer types -> print schema `#`-comments to stderr -> print header + first `args.n` data rows to stdout.

**schema**: Open in-memory SQLite db -> load all input via format-specific loader -> query `sqlite_master` for `CREATE TABLE` DDL -> print.

**stats**: Open in-memory SQLite db -> load all input -> build a SQL query with per-column aggregates (COUNT, MIN, MAX, AVG for numeric types) -> render via `table.writeTable()`.

## Integration Points

- **Consumed by**: `src/main.zig` — imports `columns_mode`, `validate_mode`, `sample_mode`, `stats_mode`, `schema_mode` from `src/modes/`. Dispatched via the `ArgsResult` tagged union from `src/args.zig`.
- **Depends on**:
  - `src/source.zig` — imported directly by all modes via `@import("source.zig")`
  - `src/loader.zig` — provides `inferTypes`, `parseHeader`, `loadCsvInput`, `fmtThousands`, `inference_buffer_size`
  - `src/csv.zig` — `csvReaderWithDelimiter` for CSV/TSV parsing
  - `src/json.zig` — JSON/NDJSON parsing, `firstJsonObject`, `readLine`
  - `src/xml.zig` — `getXmlColumnNames`, `summarizeXml`, `loadXmlInput`
  - `src/yaml.zig` — `loadYamlInput`
  - `src/sqlite.zig` — `fatal`, `readAllInput`, `openDb`, `ColumnType`, `getTableColumns`, `getTableColumnsWithTypes`, `appendQuotedId`, `appendStringLiteral`
  - `src/format.zig` — `InputFormat`, `OutputFormat`, and field-formatting helpers
  - `src/args.zig` — argument structs (`ColumnsArgs`, `ValidateArgs`, `SampleArgs`, `SchemaArgs`, `StatsArgs`), `ExitCode`, `ParsedArgs`
  - `src/table.zig` — `writeTable` (used by stats mode)
  - C API (`c`) — sqlite3 C bindings (used by schema and stats modes)
