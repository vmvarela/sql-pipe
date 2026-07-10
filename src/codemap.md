# src/

## Responsibility
Core pipeline implementation for sql-pipe: argument parsing, input format handling (CSV/TSV/JSON/NDJSON/XML), SQLite database bridge, type inference, and output formatting (CSV/TSV/JSON/NDJSON/XML/Markdown/HTML/SQL INSERT/table).

## Design

### Module Layout
| File | Role |
|------|------|
| `main.zig` | CLI entry point, mode dispatch, stdin/file detection, query execution loop |
| `args.zig` | Argument definitions, CLI parsing (getopt-style), mode structs, help text, exit codes |
| `sqlite.zig` | SQLite C FFI wrappers: `openDb`, `createTable`, `insertRow`, `execSql`, `columnText/Name`, `readAllInput`, `fatal` |
| `loader.zig` | CSV/TSV input loading pipeline: header parsing, row buffering, type inference (date/datetime/numeric detection), schema generation, INSERT statement preparation |
| `format.zig` | Input format detection (from extension + `-I` override), output format dispatch, write functions for each format |
| `csv.zig` | Streaming CSV reader with custom delimiter and quote handling |
| `json.zig` | JSON array, NDJSON, and JSONPath loading; first-object schema extraction |
| `xml.zig` | Custom streaming XML parser (`XmlParser`) with entity decoding, `navigateToRoot`, `readContent`, row/column extraction |
| `table.zig` | Pretty-printed table output (box-drawing chars), two-pass col-width computation, numeric right-alignment |
| `markdown.zig` | Markdown table output, two-pass streaming, numeric right-alignment |
| `visual.zig` | UTF-8 display-width helpers (CJK/emoji = 2, ASCII = 1), `writeCharRepeated`, `writeSpaces` |
| `completions.zig` | Shell completion generation for bash, zsh, fish |

### Patterns
- **Streaming I/O** — All readers use `std.Io.Reader` with stack-allocated buffers, no full-file reads (except JSON/XML which need complete parse)
- **Two-pass table output** — `table.zig` and `markdown.zig` first step through SQLite results to compute column widths, reset, then print — O(cols) memory, rows never buffered
- **Fail-fast errors** — `fatal()` writes to stderr with typed exit code and aborts
- **SourceFile pattern** — `source.zig` in `modes/` provides uniform file-or-stdin opening with `needs_close` flag

## Flow
1. `main.zig` parses args via `args.zig` → determines mode (query, `--columns`, `--validate`, `--sample`, `--schema`, `--stats`)
2. Input data loaded into SQLite via `loader.zig` (CSV), `json.zig`, or `xml.zig` → creates table with inferred column types
3. SQL query executed via `sqlite.zig` → if `--explain`, also runs `EXPLAIN QUERY PLAN`
4. Results formatted via `format.zig` dispatcher → written to stdout/file

## Integration
- **Consumed by**: `main.zig` entry point, `modes/*.zig` sub-commands
- **Depends on**: C FFI (`c` module, SQLite3), Zig 0.16 stdlib (`std.Io`, `std.ArrayList`, etc.)
- **Shared utility**: `visual.zig` used by both `table.zig` and `markdown.zig`
