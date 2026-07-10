# src/modes/

## Responsibility
Sub-command implementations for sql-pipe introspection and validation modes: `--columns`, `--validate`, `--sample`, `--schema`, `--stats`/`--profile`.

## Design

### Module Layout
| File | Mode | Responsibility |
|------|------|----------------|
| `columns.zig` | `--columns` | List column names from first data row; `--verbose` adds inferred types |
| `validate.zig` | `--validate` | Parse entire input, print summary: `OK: N rows, M columns (col1 TYPE, col2 TYPE, ...)` |
| `sample.zig` | `--sample N` | Print schema block to stderr, then first N data rows to stdout |
| `schema.zig` | `--schema` | Load input into temp SQLite table, print CREATE TABLE DDL |
| `stats.zig` | `--stats/--profile` | Load input into temp SQLite, run per-column stats via generated SQL (count, min, max, mean), output as pretty table |
| `source.zig` | (shared helper) | Uniform file-or-stdin opening with `SourceFile` return type and `needs_close` cleanup |

### Design Patterns

- **Shared helpers**: All modes import `source.zig` for input opening, `csv.zig`/`json.zig`/`xml.zig` for parsing, `format.zig` for type dispatch
- **Same loading path**: `columns.zig`, `schema.zig`, `stats.zig`, `validate.zig` all use `loader.loadCsvInput()` or `json_mod.loadJsonArray()` etc. — same code as the query path
- **Schema via SQLITE**: `schema.zig` loads data into SQLite then reads `sqlite_master.sql` — avoids reimplementing DDL generation
- **Stats via SQL**: `stats.zig` generates a UNION ALL query over all columns with MIN/MAX/AVG — uses SQLite's built-in aggregation

### Flow
1. `main.zig` detects mode flag → calls `runColumns()`, `runValidate()`, etc.
2. Mode function determines source (file or stdin) via `source.openInput()`
3. Data parsed according to input format: CSV reader, JSON parse, NDJSON line reader, or XML parser
4. Each mode extracts and prints its specific output (column names, row counts, DDL, stats table)
5. Stats mode loads into temporary SQLite database with `sqlite_mod.openDb(false)` (in-memory)

## Integration
- **Consumed by**: `src/main.zig` (mode dispatch via args)
- **Depends on**: `src/csv.zig`, `src/json.zig`, `src/xml.zig` (parsers), `src/loader.zig` (loading), `src/sqlite.zig` (DB bridge), `src/format.zig` (types)
- **No output format abstraction** — these modes write directly rather than using `format.writeOutput()`
