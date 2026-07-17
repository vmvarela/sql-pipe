# Repository Atlas: sql-pipe

## Project Responsibility

CLI tool that pipes structured data (CSV, TSV, JSON, NDJSON, XML, YAML) into an in-memory SQLite engine, runs a user-supplied SQL query, and emits results in eight formats (CSV, TSV, JSON, NDJSON, XML, Markdown, HTML table, SQL INSERT, pretty-printed table). Also provides ancillary modes for column listing, validation, sampling, statistics, and schema DDL generation — plus shell completion for bash/zsh/fish. Single binary, zero external dependencies, bundles SQLite amalgamation and libyaml subset.

## System Entry Points

- `src/main.zig` — CLI entry point, argument parsing, mode dispatch, pipeline orchestration
- `build.zig` — Zig build system with 120+ integration tests, bundles C deps (sqlite3, libyaml)
- `build.zig.zon` — Package manifest (name=`sql_pipe`, version=`0.0.0-dev`, min Zig `0.16.0`)

## Directory Map

| Directory | Responsibility | Detailed Map |
|-----------|---------------|--------------|
| `src/` | Core pipeline: argument parsing, multi-format I/O loaders, SQLite wrappers, output formatters (14 modules) | [View Map](src/codemap.md) |
| `src/modes/` | CLI sub-command modes: `--columns`, `--validate`, `--sample`, `--schema`, `--stats` (6 modules) | [View Map](src/modes/codemap.md) |
| `lib/` | Vendored C deps: SQLite amalgamation (`sqlite3.c/h`), libyaml subset | (vendored) |
| `tests/` | Test fixtures (CSV, JSON, NDJSON, XML sample data) + HTTP test server | (fixtures) |
| `docs/` | Man page source (`sql-pipe.1.scd`) | — |
| `packaging/` | nfpm, chocolatey, winget packaging configs | — |
| `.github/` | CI workflows, labeler, release drafter, dependabot | — |

## Architecture Overview

```
CLI args → parseArgs() → dispatch
                              │
              ┌───────────────┼──────────────┐
              │               │              │
           modes/          execQuery()     help/version
    (columns, validate,    (main path)     (print+exit)
     sample, stats,
     schema)
```

**Main pipeline** (three stages): load → query → output

```
           stdin / file(s) / HTTP(S) URL
                        │
                        ▼
┌────────────────────────────┐     ┌──────────────────┐     ┌─────────────────────┐
│ Input Loaders (per source) │────▶│ In-memory SQLite │────▶│ Output Formatters    │
│ csv, tsv, json, ndjson,   │     │ (named tables)   │     │ csv, tsv, json,      │
│ xml, yaml                  │     │                  │     │ ndjson, xml, markdown,│
└────────────────────────────┘     └───────┬──────────┘     │ html, sql, table      │
                                          │                 └──────────────────────┘
                                     SQL query                    │
                                          │                 stdout / file
                                          ▼
```

**Mode operations** bypass the query stage entirely — each mode parses input and produces a specific output directly (column names, row counts, DDL, per-column stats).

## Input Formats

| Format | Extension | Loader | Notes |
|--------|-----------|--------|-------|
| CSV | `.csv` | `loader.zig` + `csv.zig` | RFC 4180, multi-char delimiters, type inference |
| TSV | `.tsv` | `loader.zig` + `csv.zig` | Tab-delimited via CSV parser |
| JSON | `.json` | `json.zig` | Array of objects |
| NDJSON | `.ndjson` | `json.zig` | Newline-delimited, one object per line |
| XML | `.xml` | `xml.zig` | Custom streaming parser, configurable container/row elements |
| YAML | `.yaml` | `yaml.zig` | Sequence of mappings via libyaml FFI |

## Output Formats

CSV, TSV, JSON (array), NDJSON, XML, Markdown table, HTML table, SQL INSERT, pretty-printed table (box-drawing).

## Key Design Decisions

- **Single binary, zero deps** — Bundles SQLite amalgamation + libyaml subset; everything compiled via Zig build
- **Type inference** — Samples first N rows (default 100) to infer SQLite column types (DATETIME > DATE > INTEGER > REAL > TEXT ladder). Leading-zero integers (e.g. `007`) demoted to TEXT.
- **Streaming I/O** — CSV parser uses byte-level state machine; table/markdown use two-pass streaming O(cols) memory; XML/YAML/JSON parse full input
- **Mode pattern** — Sub-commands (`--columns`, `--validate`, `--sample`, `--schema`, `--stats`) are separate modules in `src/modes/`, dispatched via tagged union
- **Arena + defer** — Arena allocators for temporary allocations; explicit defer cleanup at call sites
- **Error handling** — Format-specific `fatal()` prints to stderr + exits with typed `ExitCode` (0=success, 1=usage, 2=parse, 3=SQL); SQL errors include Levenshtein-based column suggestions

## Integration Points

- **FFI**: SQLite3 C API (`sqlite3_open`, `sqlite3_prepare_v2`, `sqlite3_step`, etc.), libyaml C API (`yaml_parser_parse`, etc.)
- **HTTP**: `std.http.Client` for HTTPS URL input sources (`http.zig`)
- **Build**: `c` module (SQLite + libyaml C bindings), `yaml` module (libyaml Zig bindings), `build_options.VERSION`

## Build & Test

- `zig build` — Compile single binary
- `zig build test` — 120+ integration tests (bash-based)
- `zig build unit-test` — CSV loader unit tests
- `ziglint src build.zig` — Linting
