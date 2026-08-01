# src/modes/

## Responsibility

Implements the CLI's inspect and REPL operations. Five single-purpose modes (`--inspect columns|validate|sample|stats|schema`) inspect or validate structured data input without running an arbitrary SQL query; a native REPL mode (`--repl`) provides an interactive SQLite shell. The five inspect modes share the same input-source handling (file or stdin), format dispatch (CSV/TSV/JSON/NDJSON/XML/YAML/Parquet), and error-reporting patterns as the main pipeline, but produce a specific output (column names, validation summary, sample rows, DDL, per-column statistics). The old standalone flags (`--columns`, `--validate`, `--sample`, `--stats`, `--schema`) still work but are deprecated aliases for `--inspect <mode>`.

## Module Overview

| File | Role |
|---|---|
| `source.zig` | Shared helper: `SourceFile` struct + `openInput()` to open a file path or stdin uniformly. Used by the streaming inspect modes. |
| `inspect.zig` | `runInspect()` — thin dispatcher: switches on `InspectMode` (`columns`, `validate`, `sample`, `stats`, `schema`) and forwards `ParsedArgs` to the matching `run*` function. |
| `columns.zig` | `runColumns()` — print column names (and optionally inferred types) from header of first row. |
| `validate.zig` | `runValidate()` — parse input, count rows/columns, detect mismatched column counts, optionally infer types. |
| `sample.zig` | `runSample()` — print schema to stderr + first N data rows to stdout (CSV/TSV only; other formats load into SQLite first). |
| `schema.zig` | `runSchema()` — load data into an in-memory SQLite table, then print its `CREATE TABLE` DDL. |
| `stats.zig` | `runStats()` — load data into SQLite, then compute per-column stats (type, non-null count, min/max/mean) and render as a table. |
| `repl.zig` | `runRepl()` — native interactive REPL: loads pipeline inputs, then reads SQL statements (and dot commands) from stdin and executes them via `main.execQuery`. No external readline C dependency. |

## Design Patterns

- **Uniform function signature**: Every `run*` function takes `(allocator, io, parsed, stderr_writer, stdout_writer)` — same convention as the main query path in `main.zig`. Since v0.22 all five inspect modes receive the full `ParsedArgs` directly; the per-mode `ColumnsArgs`/`ValidateArgs`/`SampleArgs`/`SchemaArgs`/`StatsArgs` structs were deleted.
- **Fused dispatch (`inspect.zig`)**: One entry point, `runInspect()`, switches on the `InspectMode` enum and forwards to the mode's `run*` function. `args.zig` maps `--inspect <mode>` (and the deprecated standalone flags) onto the single `.inspect` `ArgsResult` variant carrying `InspectArgs{ mode, sample_n, deprecated }`.
- **Input-source abstraction (`source.zig`)**: Streaming modes use `source.openInput(io, input_source, stderr_writer)` returning a `SourceFile` with a `needs_close` flag (released via `deinit(io)`). This avoids duplicating the file-vs-stdin branching in every mode. Schema/stats/REPL don't use it — they load via the main pipeline's `loadPipelineInputs` instead.
- **Format dispatch via switch**: Each inspect mode matches on `parsed.input_format` (`.csv`, `.tsv`, `.json`, `.ndjson`, `.xml`, `.yaml`, `.parquet`) and calls the appropriate parser module. JSON/NDJSON branches read the full input into memory; CSV/TSV branches stream via `csvReaderWithDelimiter`; YAML loads into a temporary SQLite database via `yaml_mod.loadYamlInput`; XML uses `xml_mod.getXmlColumnNames` or `xml_mod.summarizeXml`.
- **Two-phase architecture (schema + stats modes)**: `schema.zig` and `stats.zig` load data into an in-memory SQLite database first, then query `sqlite_master` or run aggregate SQL to produce output. Since v0.22 they reuse the caller's `ParsedArgs` — just null out `max_rows` — and delegate input loading to `main_mod.loadPipelineInputs`, the same function the main query path uses.
- **Streaming (columns + validate + sample modes)**: `columns.zig`, `validate.zig`, and `sample.zig` process CSV/TSV data incrementally with a row buffer capped at `inference_buffer_size` for type inference, then stream remaining rows for counting.
- **Type inference**: Modes that support it (`columns --verbose`, `validate`, `sample`) use `loader.inferTypes()` on a buffered subset of rows. When `type_inference` is disabled, all columns default to `TEXT`.
- **Error handling**: All modes use the shared `fatal()` function from `sqlite.zig` to print a structured error to stderr and exit with the appropriate `ExitCode`. The REPL instead catches errors per-query (`PrepareQueryFailed` and friends) and prints via `printSqlError` / `error: {s}` without exiting, so the session survives a bad statement.
- **Printer convention**: `columns.zig` and `validate.zig` write directly to stdout/stderr with `writer.print`. `schema.zig` prints raw DDL. `stats.zig` routes output through `table.writeTable()`. `sample.zig` splits output: schema (`#`-prefixed comments) to stderr, data rows to stdout. The REPL routes query output through `main.execQuery` (table/CSV/etc. per `parsed.output_format` and `use_table`), with prompts and load messages on stderr to keep stdout clean for piping.
- **Native REPL without readline**: `repl.zig` implements the read-eval-print loop with `std.Io` — a persistent `std.Io.File.reader` on Unix (buffer survives across calls via pointer) and a `c_stdio` `getc()` fallback on Windows. No linenoise C dependency (removed in v0.22, -50KB binary). Multi-line statements accumulate in an `ArrayList` until a `;`, empty line, or trailing `;` executes; dot commands (`.help`, `.tables`, `.schema`, `.read`, `.exit/.quit/.q`) only run in single-line mode. Prompt and warnings go to stderr.

## Data & Control Flow

```
main.zig
  └─ parseArgs() -> ArgsResult
       ├─ .inspect -> inspect_mode.runInspect(mode, parsed)
       │    ├─ .columns  -> columns_mode.runColumns()
       │    ├─ .validate -> validate_mode.runValidate()
       │    ├─ .sample   -> sample_mode.runSample()
       │    ├─ .stats    -> stats_mode.runStats()
       │    └─ .schema   -> schema_mode.runSchema()
       ├─ .repl    -> repl_mode.runRepl()
       └─ .parsed  -> main query path (not in modes/)
```

Streaming inspect modes (columns/validate/sample):

1. Determines input source: `parsed.files[0]` path, or stdin if no files.
2. Calls `source.openInput(io, input_source, stderr_writer)` -> `SourceFile`.
3. Dispatches on `parsed.input_format` to the appropriate parser.
4. Processes data and writes output to stdout/stderr.
5. Cleans up (closes file via `SourceFile.deinit` if not stdin, frees allocated memory).

SQLite-backed modes (schema/stats) and the REPL skip steps 1–3 and instead route all input loading through `main_mod.loadPipelineInputs(allocator, io, db, parsed, stderr_writer)` — the exact loader used by the main query path — so files, stdin, URLs, and all formats behave identically to query mode.

### Per-mode data flow details

**inspect**: One switch on `InspectMode` forwarding `parsed` unchanged to the mode's `run*` function. `main.zig` prints a deprecation warning first when the mode came from an old standalone flag (`inspect_args.deprecated`).

**columns**: Read header row -> parse column names -> optionally buffer N rows for type inference -> print `column_name [TYPE]` lines.

**validate**: Read header -> parse columns -> buffer up to `inference_buffer_size` rows -> optionally infer types -> stream remaining rows counting mismatches -> print `OK: <count> rows, <N> columns (<col TYPE, ...>)`.

**sample**: CSV/TSV only (other formats require loading into SQLite first — ponytail noted in code). Read header -> parse columns -> buffer `max(inference_buffer_size, parsed.sample_n)` rows -> optionally infer types -> print schema `#`-comments to stderr -> print header + first `parsed.sample_n` data rows to stdout.

**schema**: Open in-memory SQLite db -> null out `parsed.max_rows` -> `main_mod.loadPipelineInputs` loads all input -> query `sqlite_master` for `CREATE TABLE` DDL -> print.

**stats**: Open in-memory SQLite db -> null out `parsed.max_rows` -> `main_mod.loadPipelineInputs` loads all input -> build a SQL query with per-column aggregates (COUNT, MIN, MAX, AVG for numeric types) -> render via `table.writeTable()`.

**repl**: Open db (`parsed.disk`/`parsed.save_path` respected) -> `main_mod.loadPipelineInputs` loads all inputs -> print `Loaded N rows` to stderr -> loop: write prompt (`sql> ` or `...> `) to stderr, read line (Unix `std.Io` reader / Windows c_stdio `getc`), accumulate until `;` or empty line, then execute via `main_mod.execQuery` (results to stdout per `parsed.output_format` + `use_table`). Dot commands handled only in single-line mode; `.exit`/`.quit`/`.q`/Ctrl-D break the loop. Query errors are printed and the loop continues.

## Integration Points

- **Consumed by**: `src/main.zig` — imports `inspect_mode` and `repl_mode` from `src/modes/`. Dispatched via the `ArgsResult` tagged union from `src/args.zig` (`.inspect` variant with `InspectArgs{ mode, sample_n, deprecated }`, `.repl` variant).
- **Depends on**:
  - `src/modes/inspect.zig` (used by main) and the five mode files (used by inspect.zig) — `inspect.zig` imports `columns.zig`, `validate.zig`, `sample.zig`, `stats.zig`, `schema.zig`
  - `src/args.zig` — `ParsedArgs` (shared by all modes), `InspectMode`, `InspectArgs`, `ExitCode`; mode-specific `ColumnsArgs`/`ValidateArgs`/`SampleArgs`/`SchemaArgs`/`StatsArgs` structs deleted in v0.22
  - `src/main.zig` — `loadPipelineInputs`, `execQuery`, `mainTableName` (used by `schema.zig`, `stats.zig`, `repl.zig`)
  - `src/source.zig` — imported by the streaming modes via `@import("source.zig")`
  - `src/loader.zig` — provides `inferTypes`, `parseHeader`, `loadCsvInput`, `fmtThousands`, `inference_buffer_size`
  - `src/csv.zig` — `csvReaderWithDelimiter` for CSV/TSV parsing
  - `src/json.zig` — JSON/NDJSON parsing, `firstJsonObject`, `readLine`
  - `src/xml.zig` — `getXmlColumnNames`, `summarizeXml`, `loadXmlInput`
  - `src/yaml.zig` — `loadYamlInput`
  - `src/sqlite.zig` — `fatal`, `printSqlError`, `readAllInput`, `openDb`, `ColumnType`, `getTableColumns`, `getTableColumnsWithTypes`, `appendQuotedId`, `appendStringLiteral`
  - `src/format.zig` — `InputFormat`, `OutputFormat`, and field-formatting helpers
  - `src/table.zig` — `writeTable` (used by stats mode)
  - C API (`c`) — sqlite3 C bindings (used by schema, stats, and repl modes)
  - `builtin` — `os.tag` check in `repl.zig` to select the Windows c_stdio fallback vs the Unix `std.Io` reader
