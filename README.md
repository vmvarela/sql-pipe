# sql-pipe

[![CI](https://github.com/vmvarela/sql-pipe/actions/workflows/ci.yml/badge.svg)](https://github.com/vmvarela/sql-pipe/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

`sql-pipe` reads CSV from stdin, loads it into an in-memory SQLite database, runs a SQL query, and prints the results. No server, no schema file, no configuration — just pipe and query.

It exists because `awk` is cryptic, Python startup is annoying, and `sqlite3 :memory:` requires too much ceremony. If you know SQL and work with CSV in the terminal, this is the tool you've been shelling out for.

```sh
$ curl -s https://example.com/data.csv | sql-pipe 'SELECT region, SUM(revenue) FROM t GROUP BY region ORDER BY 2 DESC'
```

## Quick Start

### Download a binary

Pre-built binaries for Linux, macOS (Intel + Apple Silicon), and Windows are available on the [Releases page](https://github.com/vmvarela/sql-pipe/releases).

### Build from source

Requires [Zig 0.15+](https://ziglang.org/download/). SQLite is compiled from the official amalgamation so there are no system dependencies.

```sh
git clone https://github.com/vmvarela/sql-pipe
cd sql-pipe
# Download the SQLite amalgamation (one-time setup)
mkdir -p lib
curl -fsSL https://www.sqlite.org/2025/sqlite-amalgamation-3490100.zip -o sqlite.zip
unzip -j sqlite.zip '*/sqlite3.c' '*/sqlite3.h' -d lib/
zig build -Dbundle-sqlite=true -Doptimize=ReleaseSafe
# binary is at ./zig-out/bin/sql-pipe
```

## Usage

```
sql-pipe '<SQL query>'
```

The CSV is read from stdin. The first row must be the header — column names become the schema for table `t`. Results are printed to stdout as comma-separated values.

```sh
$ printf 'name,age\nAlice,30\nBob,25\nCarol,35' | sql-pipe 'SELECT * FROM t'
Alice,30
Bob,25
Carol,35
```

## Examples

**Filter rows by value:**

```sh
$ cat users.csv | sql-pipe 'SELECT name, email FROM t WHERE country = "ES"'
```

**Aggregate with numeric comparison** — all columns are TEXT, so cast explicitly when comparing numbers:

```sh
$ cat orders.csv | sql-pipe 'SELECT COUNT(*), AVG(CAST(amount AS REAL)) FROM t WHERE status = "paid"'
142,87.35
```

**Top N by column:**

```sh
$ cat logs.csv | sql-pipe 'SELECT path, COUNT(*) as hits FROM t GROUP BY path ORDER BY hits DESC LIMIT 10'
```

**Column names with spaces** work — just quote them in your SQL:

```sh
$ cat report.csv | sql-pipe 'SELECT "first name", "last name" FROM t WHERE "dept id" = "42"'
```

**Chain queries** by piping output back in:

```sh
$ cat events.csv \
  | sql-pipe 'SELECT user_id, COUNT(*) as n FROM t GROUP BY user_id' \
  | sql-pipe 'SELECT * FROM t WHERE CAST(n AS INT) > 100'
```

**Use with other Unix tools:**

```sh
# Deduplicate a CSV column and sort
$ cut -d, -f1 data.csv | tail -n+2 | sort -u

# Or let sql-pipe do it
$ cat data.csv | sql-pipe 'SELECT DISTINCT category FROM t ORDER BY 1'
```

## How it works

Each invocation opens a fresh `:memory:` SQLite database. The header row drives a `CREATE TABLE t (...)` with all columns as `TEXT`. Rows are loaded inside a single transaction via a prepared `INSERT INTO t VALUES (?, ?, ...)` statement. Then `sqlite3_exec` runs your query, and results are printed line by line.

Because the database never touches disk, it vanishes the moment the process exits. There is no state, no cleanup, and no surprises.

## Limitations

- **All columns are `TEXT`.** Numeric sorting and comparisons require `CAST(col AS INT)` or `CAST(col AS REAL)`. Automatic type inference is planned ([#4](https://github.com/vmvarela/sql-pipe/issues/4)).
- **No RFC 4180 quoted fields yet.** Fields containing commas or embedded newlines will be parsed incorrectly ([#3](https://github.com/vmvarela/sql-pipe/issues/3)).
- **Single table per invocation.** For multi-table joins, chain with a second `sql-pipe` or use a `WITH` CTE that re-expresses the logic.
- **No output header row.** The result is raw data rows only ([#10](https://github.com/vmvarela/sql-pipe/issues/10)).

## Related

- **[sqlite-utils](https://sqlite-utils.datasette.io/)** — better if you need persistent databases, schema management, or Python integration.
- **[q](https://harelba.github.io/q/)** — similar concept in Python; supports quoted CSV fields and more formats.
- **[trdsql](https://github.com/noborus/trdsql)** — Go alternative with multi-format support (JSON, LTSV, TBLN) and output formatting.

