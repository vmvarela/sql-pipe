# Repository Atlas: sql-pipe

## Project Responsibility
CLI tool that loads CSV/TSV/JSON/NDJSON/XML data into in-memory SQLite, executes SQL queries, outputs results in multiple formats (CSV, TSV, JSON, NDJSON, XML, Markdown, HTML, SQL INSERT, pretty table). Single binary, zero external dependencies, bundled SQLite.

## System Entry Points
- `src/main.zig` — CLI entry point, argument parsing, mode dispatch, I/O setup
- `build.zig` — Zig build system with 120+ integration tests

## Directory Map (Aggregated)

| Directory | Responsibility Summary | Detailed Map |
|-----------|------------------------|--------------|
| `src/` | Core pipeline: argument parsing, input loading, SQLite execution, output formatting | [View Map](src/codemap.md) |
| `src/modes/` | Sub-command implementations (`--columns`, `--validate`, `--sample`, `--schema`, `--stats`) | [View Map](src/modes/codemap.md) |
| `tests/fixtures/` | Sample CSV/JSON/NDJSON/XML files for integration tests | (fixtures only) |
| `lib/` | Bundled SQLite amalgamation (sqlite3.c, sqlite3.h) | (vendored C) |

## Data Flow Overview
```
stdin / file(s)
      │
      ▼
┌─────────────────┐     ┌──────────────────┐     ┌─────────────────┐
│ Input Loaders   │────▶│ In-memory SQLite │────▶│ Output Formatters│
│ (csv, json,     │     │ (sqlpipe_* tables)│    │ (csv, json,     │
│  ndjson, xml)   │     │                   │     │  table, md, etc)│
└─────────────────┘     └──────────────────┘     └─────────────────┘
      │                         │                       │
      │                    ┌────┴────┐                  │
      │                    │  SQL    │                  │
      │                    │  Query  │                  │
      │                    └────┬────┘                  │
      │                         ▼                       │
      └──────────────────▶ stdout/stderr ◀───────────────┘
```

## Key Architectural Decisions
- **Single binary, zero deps** — Bundles SQLite amalgamation; no external dependencies
- **Streaming I/O** — Buffered readers, no full-file buffering (except XML/JSON which need full parse)
- **Type inference** — Samples first N rows (default 1000) to infer SQLite column types
- **Mode pattern** — Each sub-command (`--columns`, `--validate`, etc.) is a separate module in `src/modes/`
- **Zig 0.16 `std.Io`** — Uses new `std.Io.Reader`/`Writer` abstractions with buffered file I/O
- **Arena allocators** — Used for temporary allocations during query execution
- **Error handling** — `fatal()` helper prints to stderr and exits with typed `ExitCode`

## Integration Points
- **CLI args** → `src/args.zig` → parsed into `ParsedArgs` + mode-specific structs
- **Input formats** → `format.InputFormat` enum → dispatcher in `loader.loadInput()`
- **Output formats** → `format.OutputFormat` enum → dispatcher in `format.writeOutput()`
- **SQLite** → `src/sqlite.zig` wraps C API; all SQL errors → `fatal()` with `ExitCode.sql_error`

## Build & Test
- `zig build test` — 120+ integration tests (bash-based) + XML unit tests
- `zig build unit-test` — CSV loader unit tests with leak detection
- `ziglint src build.zig` — Linting
