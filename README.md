# sql-pipe

[![CI](https://github.com/vmvarela/sql-pipe/actions/workflows/ci.yml/badge.svg)](https://github.com/vmvarela/sql-pipe/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/vmvarela/sql-pipe)](https://github.com/vmvarela/sql-pipe/releases/latest)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

`sql-pipe` reads CSV, JSON, NDJSON, YAML, XML, or Parquet from stdin or file arguments, loads it into an in-memory SQLite database, runs a SQL query, and prints the results. No server, no schema files, no setup. Use `--save` to persist the database to a file for later reuse.

It exists because `awk` is cryptic, spinning up a Python interpreter for a one-liner feels wrong, and `sqlite3 :memory:` takes four commands before you can query anything. If you know SQL and work with CSV in the terminal, this is the tool you've been reaching for.

```sh
$ sql-pipe --url https://example.com/data.csv 'SELECT region, SUM(revenue) FROM t GROUP BY region ORDER BY 2 DESC'

# Or pass files directly — each file becomes a table named after its basename
$ sql-pipe orders.csv 'SELECT * FROM orders WHERE amount > 100'
```

## Quick Start

**macOS / Linux via Homebrew:**

```sh
brew tap vmvarela/homebrew-tap
brew install sql-pipe
```

**Pre-built binaries** for Linux, macOS (Intel + Apple Silicon), and Windows are also available on the [Releases page](https://github.com/vmvarela/sql-pipe/releases).

**Shell installer (Linux/macOS):**

```sh
curl -sSL https://raw.githubusercontent.com/vmvarela/sql-pipe/master/install.sh | sh
```

By default it installs to `/usr/local/bin`. Override with `INSTALL_DIR`:

```sh
curl -sSL https://raw.githubusercontent.com/vmvarela/sql-pipe/master/install.sh | INSTALL_DIR="$HOME/.local/bin" sh
```

**npm (Node.js ≥ 18):**

```sh
npm install -g @vmvarela/sql-pipe
```

**Debian / Ubuntu (APT repository):**

```sh
curl -sSL https://vmvarela.github.io/apt-packages/key.gpg \
  | sudo tee /etc/apt/keyrings/vmvarela.asc
echo "deb [signed-by=/etc/apt/keyrings/vmvarela.asc] https://vmvarela.github.io/apt-packages stable main" \
  | sudo tee /etc/apt/sources.list.d/vmvarela.list
sudo apt update && sudo apt install sql-pipe
```

Or install a single release asset directly:

```sh
wget https://github.com/vmvarela/sql-pipe/releases/latest/download/sql-pipe_VERSION_linux_amd64.deb
sudo dpkg -i sql-pipe_VERSION_linux_amd64.deb
```

Replace `VERSION` with the release version (e.g. `0.12.0`) and `amd64` with your architecture (`arm64`, `arm7`, or `386`).

**Fedora / RHEL / openSUSE (RPM repository):**

```sh
sudo curl -fsSL https://vmvarela.github.io/rpm-packages/vmvarela.repo \
  -o /etc/yum.repos.d/vmvarela.repo
sudo dnf install sql-pipe
```

Or install a single release asset directly:

```sh
sudo rpm -i https://github.com/vmvarela/sql-pipe/releases/latest/download/sql-pipe_VERSION_linux_amd64.rpm
```

Replace `VERSION` with the release version (e.g. `0.12.0`) and `amd64` with your architecture (`arm64`).

**Alpine Linux (APK repository):**

```sh
wget -qO /etc/apk/keys/vmvarela.rsa.pub \
  https://vmvarela.github.io/apk-packages/vmvarela.rsa.pub
echo "https://vmvarela.github.io/apk-packages" >> /etc/apk/repositories
apk update && apk add sql-pipe
```

Or install a single release asset directly:

```sh
wget https://github.com/vmvarela/sql-pipe/releases/latest/download/sql-pipe_VERSION_linux_amd64.apk
sudo apk add --allow-untrusted sql-pipe_VERSION_linux_amd64.apk
```

Replace `VERSION` with the release version (e.g. `0.12.0`) and `amd64` with your architecture (`arm64`).

**Arch Linux (AUR):** install with your preferred AUR helper:

```sh
yay -S sql-pipe
# or
paru -S sql-pipe
```

**Nix / NixOS:**

```sh
# Run without installing
nix run github:vmvarela/nix-packages#sql-pipe -- 'SELECT * FROM t'

# Install to profile
nix profile install github:vmvarela/nix-packages#sql-pipe

# Non-flake
nix-env -if https://github.com/vmvarela/nix-packages/archive/main.tar.gz
```

**Windows (WinGet):**

```powershell
winget install vmvarela.sql-pipe
```

**Windows (Scoop):**

```powershell
scoop bucket add vmvarela https://github.com/vmvarela/scoop-bucket
scoop install sql-pipe
```

To build from source (requires [Zig 0.16+](https://ziglang.org/download/)):

```sh
git clone https://github.com/vmvarela/sql-pipe
cd sql-pipe
mkdir -p lib
curl -fsSL https://www.sqlite.org/2025/sqlite-amalgamation-3490100.zip -o sqlite.zip
unzip -j sqlite.zip '*/sqlite3.c' '*/sqlite3.h' -d lib/
zig build -Dbundle-sqlite=true -Doptimize=ReleaseSafe
```

Binary lands at `./zig-out/bin/sql-pipe`. SQLite and compression libraries are compiled from source — no system dependencies.

## Usage

Input comes from stdin or file arguments. For CSV and TSV, the first row must be a header — those column names become the schema. Results go to stdout as comma-separated values by default.

### URL input (table `t`)

Use `-u` / `--url` to fetch HTTP or HTTPS input into table `t`. File arguments remain available, but stdin is ignored when `--url` is used. Set `-I` when the URL does not reveal its format. Repeat `--http-header` for request headers; `--max-body-size` limits the response body and defaults to `104857600` bytes (100MB).

```sh
$ sql-pipe --url https://example.com/orders.csv --http-header 'Authorization: Bearer token' \
    'SELECT * FROM t'
```

### Stdin input (table `t`)

When reading from stdin, data is loaded into a table called `t`:

```sh
$ printf 'name,age\nAlice,30\nBob,25\nCarol,35' | sql-pipe 'SELECT * FROM t'
Alice,30
Bob,25
Carol,35
```

When stdout is a terminal (not piped), results are automatically formatted as an aligned table:

```sh
$ printf 'name,age\nAlice,30\nBob,25\nCarol,35' | sql-pipe 'SELECT * FROM t'
┌───────┬─────┐
│ name  │ age │
├───────┼─────┤
│ Alice │  30 │
│ Bob   │  25 │
│ Carol │  35 │
└───────┴─────┘
```

Numeric columns are right-aligned, text columns left-aligned. Pipe the output and it stays CSV — no behavior change for scripts. Use `--table` to force table output or `--no-table` to force CSV.

### Custom NULL representation

SQL NULL values show as the literal string `NULL` in CSV, TSV, and table output by default. Use `--null-value` to pick your own:

```sh
$ printf 'name,email\nAlice,alice@example.com\nBob,\nCarol,carol@example.com' \
  | sql-pipe --null-value '' 'SELECT * FROM t'
Alice,alice@example.com
Bob,
Carol,carol@example.com
```

Pass `--null-value ''` for an empty string, `--null-value 'N/A'`, or any other label that better fits your downstream tool. Has no effect on JSON output (JSON always uses native `null`).

For JSON and NDJSON input, pass `-I json` (reads an array of objects) or `-I ndjson` (one object per line). Column names are taken from the keys of the first object:

```sh
$ printf '[{"name":"Alice","score":95},{"name":"Bob","score":72}]' \
  | sql-pipe -I json 'SELECT name, score FROM t WHERE score > 80'
Alice,95
```

For YAML input, pass `-I yaml` (reads a top-level sequence of mappings). Both `.yaml` and `.yml` extensions are auto-detected. All values are loaded as `TEXT`:

```sh
$ cat users.yaml
- name: Alice
  country: US
- name: Bob
  country: UK
- name: Carol
  country: DE

$ cat users.yaml | sql-pipe -I yaml 'SELECT name FROM t WHERE country != "US" ORDER BY name'
Bob
Carol
```

YAML is auto-detected from the `.yaml` and `.yml` extensions, or use `-I yaml` explicitly. Comments (`#`), flow-style mappings (`[{name: Alice}]`), and standard scalar types (strings, numbers, booleans) work transparently. Multi-document streams and anchors/aliases are rejected with a clear error.

Columns are auto-detected as `INTEGER`, `REAL`, `DATE`, `DATETIME`, or `TEXT` based on the first 100 rows. Date and datetime values are normalized to ISO 8601 on insert, so SQLite date functions (`date()`, `strftime()`, `julianday()`) work immediately. Use `--no-type-inference` to force all columns to `TEXT`:

```sh
$ cat orders.csv | sql-pipe 'SELECT COUNT(*), AVG(amount) FROM t WHERE status = "paid"'
142,87.35
```

Column names with spaces work — quote them in SQL:

```sh
$ cat report.csv | sql-pipe 'SELECT "first name", "last name" FROM t WHERE "dept id" = "42"'
```

Use a custom input delimiter with `-d` / `--delimiter` (1–8 characters), or `--tsv` for tab-separated files:

```sh
$ cat data.psv | sql-pipe -d '|' 'SELECT * FROM t'
$ cat data.tsv | sql-pipe --tsv 'SELECT * FROM t'
# equivalent:
$ cat data.tsv | sql-pipe --delimiter '\t' 'SELECT * FROM t'
# multi-character delimiters:
$ cat data.psv | sql-pipe -d '||' 'SELECT * FROM t'
$ cat report.txt | sql-pipe --delimiter '  ' 'SELECT * FROM t'   # two spaces
```

Output results as a JSON array of objects with `--json`:

```sh
$ printf 'name,age\nAlice,30\nBob,25' | sql-pipe --json 'SELECT * FROM t'
[{"name":"Alice","age":30},{"name":"Bob","age":25}]
```

`--json` is mutually exclusive with `-H`/`--header`. It can be combined with `-d`/`--delimiter` and `--tsv` to read non-comma-separated input.

For XML input and output, use `-I xml` / `-O xml`. By default the root element is `<results>` and each row is `<row>`. Override with `--xml-root` and `--xml-row`:

```sh
$ printf 'name,age\nAlice,30\nBob,25' | sql-pipe -O xml 'SELECT * FROM t'
<?xml version="1.0" encoding="UTF-8"?>
<results>
<row><name>Alice</name><age>30</age></row>
<row><name>Bob</name><age>25</age></row>
</results>

$ cat data.xml | sql-pipe -I xml 'SELECT name FROM t WHERE age > 25'
```

Real-world XML documents (RSS feeds, API responses) nest rows inside a container element. Use `--xml-root` to navigate to the row container and `--xml-row` to filter by element tag:

```sh
# Query an RSS feed: channel/item → rows
$ sql-pipe --url https://feeds.feedburner.com/TheHackersNews -I xml \
    --xml-root channel --xml-row item 'SELECT title FROM t LIMIT 5'

# Query XML with a custom root and row name
$ cat events.xml | sql-pipe -I xml --xml-root events --xml-row event \
    'SELECT name, date FROM t WHERE type = "conference"'
```

### File arguments

Pass files as positional arguments instead of piping through stdin. Each file becomes a table named after its basename (without extension). The input format is auto-detected from the file extension (`.csv`, `.tsv`, `.json`, `.ndjson`, `.yaml`, `.yml`, `.xml`, `.parquet`):

```sh
# Single file — no more cat
$ sql-pipe orders.csv 'SELECT * FROM orders WHERE amount > 100'

# Parquet file — extension auto-detected, no -I needed
$ sql-pipe data.parquet 'SELECT name FROM data WHERE active = true'

# YAML file — .yaml and .yml both auto-detect
$ sql-pipe users.yaml 'SELECT name FROM users WHERE country = "US"'

# Multi-file join — the #1 reason people reach for DuckDB
$ sql-pipe orders.csv customers.csv \
    'SELECT c.name, SUM(o.amount) FROM orders o
     JOIN customers c ON o.cust_id = c.id GROUP BY c.name'
```

Gzip-compressed inputs are handled transparently (gzip only). A file ending in `.gz`
is decompressed automatically; the format is detected from the inner extension, and
the table name comes from the inner basename:

```sh
$ sql-pipe data.csv.gz 'SELECT COUNT(*) FROM data'
```

Gzipped stdin is detected by its magic bytes, so both decompressed and compressed
pipes work:

```sh
$ zcat huge.csv.gz | sql-pipe 'SELECT * FROM t'          # decompressed by zcat
$ gzip -c data.ndjson | sql-pipe 'SELECT * FROM t'       # gzip stdin magic detection
```

Use `-I` to override auto-detection when the extension is wrong or ambiguous (`.txt`, `.dat`):

```sh
$ sql-pipe -I tsv data.txt 'SELECT * FROM data'
```

Stdin works as table `t`. Mix stdin with file arguments:

```sh
# Stdin as t, file as named table
$ cat events.csv | sql-pipe users.csv 'SELECT * FROM t JOIN users ON t.uid = users.id'

# Stdin still works the old way
$ cat data.csv | sql-pipe 'SELECT * FROM t'
```

Use `--` to separate files from the query when needed (e.g. if a filename starts with `-`):

```sh
$ sql-pipe -- data.csv 'SELECT * FROM data'
```

Chain queries by piping back in — useful for two-pass aggregations. Pass `-H` to the first call so the second one sees column names:

```sh
$ cat events.csv \
  | sql-pipe -H 'SELECT user_id, COUNT(*) as n FROM t GROUP BY user_id' \
  | sql-pipe 'SELECT * FROM t WHERE n > 100'
```

### Query from file

For complex queries, store the SQL in a file and pass it with `-f` / `--file`:

```sh
$ sql-pipe -f analysis.sql orders.csv
$ cat data.csv | sql-pipe -f analysis.sql
$ sql-pipe --file=query.sql orders.csv customers.csv
```

When `-f` is used, all positional arguments are treated as data files (no positional query needed).

### Before asking for a flag: SQL and the shell already do it

sql-pipe pipes data into SQLite — column transformation and file comparison are
solved by SQL and standard shell tools, no dedicated flags needed.

**Select, rename, or cast columns** — use plain SQL instead of load-time flags:

```sh
# select + rename
sql-pipe data.csv 'SELECT name, amount AS revenue FROM t'
# cast (e.g. keep ZIP leading zeros)
sql-pipe data.csv 'SELECT CAST(zip AS TEXT) AS zip, amount FROM t'
```

**Compare schemas of two files** — compose `--schema` with `diff`:

```sh
diff <(sql-pipe --schema v1.csv) <(sql-pipe --schema v2.csv)
```

### Flags

| Flag | Description |
|------|-------------|
| `-d`, `--delimiter <char>` | Input field delimiter (single character, default `,`) |
| `--tsv` | Alias for `--delimiter '\t'` |
| `-I`, `--input-format <fmt>` | Input format: `csv` (default), `tsv`, `json`, `ndjson`, `yaml`, `xml`, `parquet`. Overrides file extension auto-detection. Both `.yaml` and `.yml` file extensions auto-detect to `yaml`. |
| `-O`, `--output-format <fmt>` | Output format: `csv` (default), `tsv`, `json`, `ndjson`, `xml`, `markdown` (alias: `md`), `html`, `sql` |
| `--sql-table <name>` | Target table name for `-O sql` INSERT output (default: `t`) |
| `--no-type-inference` | Treat all columns as TEXT (skip auto-detection) |
| `-H`, `--header` | Print column names as the first output row (CSV/TSV/HTML) |
| `--json` | Alias for `--output-format json` (mutually exclusive with `-H`) |
| `--max-rows <n>` | Stop if more than `n` data rows are read (exit 1) |
| `-u`, `--url <url>` | Fetch HTTP/HTTPS input into table `t`. Stdin is ignored; file arguments remain allowed. |
| `--http-header <header>` | Request header for `--url`, in `Key: Value` form. Repeat for multiple headers. Requests with headers do not follow redirects; headerless requests follow up to five. |
| `--max-body-size <bytes>` | Maximum `--url` response body size (default: `104857600`, 100MB). |
| `--validate` | Parse the entire input and print a summary (`OK: <n> rows, <m> columns (col TYPE, ...)`) to stdout. Exit 0 on success, exit 2 on parse error. No query required. Compatible with `--delimiter`, `--tsv`, `--no-type-inference`, `-I`/`--input-format` (csv, tsv, json, ndjson, yaml, xml). JSON/NDJSON/YAML/XML columns are reported as TEXT. |
| `--columns` | **Deprecated.** Use `--inspect columns` instead. Read the input header, print each column name on its own line, and exit 0. Supports CSV, TSV, JSON, NDJSON, YAML, and XML input. With `-v`/`--verbose`, also shows the inferred type per column (`name INTEGER`). Respects `--delimiter` and `--tsv`. Mutually exclusive with a query argument. |
| `--sample [<n>]` | **Deprecated.** Use `--inspect sample` instead. Print a schema comment block to stderr and the first `<n>` data rows to stdout as CSV (default: `n=10`). The schema block lists each column name and its inferred type, prefixed with `#`. Implies `--header`. Compatible with `--delimiter` and `--tsv`. Mutually exclusive with `--json` and a query argument. No query required. |
| `--stats` | **Deprecated.** Use `--inspect stats` instead. Load input and print per-column statistics (column name, type, non-null count, min, max, mean) as a formatted table. Mean is blank for non-numeric columns. Compatible with `--delimiter`, `--tsv`, `--no-type-inference`, `-I`/`--input-format`. Mutually exclusive with a query, `--columns`, `--validate`, `--sample`, and `--output`. |
| `--profile` | Alias for `--stats` |
| `--schema` | **Deprecated.** Use `--inspect schema` instead. Load input and print the inferred `CREATE TABLE` DDL to stdout. One DDL block per input file; stdin uses table `t`. Compatible with `--delimiter`, `--tsv`, `--no-type-inference`, `-I`/`--input-format`. Mutually exclusive with a query, `--columns`, `--validate`, `--sample`, `--stats`, `--output`, `--save`, and `-f`/`--file`. |
| `--inspect <mode>` | Inspect input data without running a query. `<mode>` is one of: `columns` (list column names, one per line; with `-v` shows inferred types), `validate` (parse entire input, print summary: `OK: <n> rows, <m> columns`), `sample` [`<n>`] (print schema comment block and first `<n>` rows as CSV, default 10), `stats` (per-column statistics: type, non-null count, min, max, mean), `schema` (print inferred CREATE TABLE DDL). Mutually exclusive with a query argument, `--output`, `--explain`, and other inspect modes. Compatible with `--delimiter`, `--tsv`, `--no-type-inference`, `-I`/`--input-format` (csv, tsv, json, ndjson, yaml, xml, parquet). `--sample` implies `--header`. `--sample` and `--stats` are mutually exclusive with `--json` output. |
| `-S`, `--save <file>` | Use `<file>` as the SQLite database instead of an in-memory database. The file persists after sql-pipe exits and can be queried with `sqlite3`. Implies disk-backed behavior; cannot be combined with `--disk` or special modes (`--columns`, `--validate`, `--sample`, `--stats`, `--schema`, `--explain`). |
| `--disk` | Use a file-backed temporary database instead of `:memory:`. Enables processing datasets larger than available RAM. Cannot be combined with `--save`. |
| `--no-stdin` | Do not read from stdin. Prevents hangs in CI pipelines where stdin is a non-TTY pipe without EOF. |
| `--explain` | Print the SQLite query plan to stderr before executing the query. Each line is prefixed with `QUERY PLAN: `. The actual query still runs and results go to stdout. Mutually exclusive with `--columns`, `--validate`, `--sample`, `--stats`, `--schema`, and `--output`. |
| `-r`, `--repl` | Enter interactive REPL mode after loading input data. Loads input once into SQLite, then presents a `sql>` prompt for interactive queries. Type `.exit`, `.quit`, `.q`, Ctrl-D, or Ctrl-C to exit. No query argument required. Cannot be combined with special modes, `-f`/`--file`, `--explain`, or `--output`. Compatible with `--save`, `--disk`, `-O`, and file arguments. |
| `--xml-root <name>` | Root element name for XML I/O (default: `results`) |
| `--xml-row <name>` | Row element name for XML I/O (default: `row`) |
| `--output <file>` | Write results to the given file instead of stdout. Creates or overwrites the file. Exits 1 if the file cannot be created. |
| `--table` | Force pretty-printed table output (auto-detected when stdout is a TTY). Requires CSV/TSV output format. |
| `--no-table` | Force CSV output even when stdout is a TTY |
| `--null-value <string>` | Custom NULL representation in CSV/TSV/table output (default: `NULL`). JSON always uses native `null`. |
| `--html-class <class>` | CSS class name for the HTML `<table>` element (`-O html` only) |
| `--checksum` | Compute the SHA-256 hash of the result set and print it to stderr as `checksum: <hash>`. The hash covers only stdout output (the result set), not stderr messages. Works with all output formats, `--output`, `--disk`, `--save`, `--repl`, `--explain`, and `--verbose`. Skipped in inspect modes (`--columns`, `--validate`, `--sample`, `--stats`, `--schema`) since they don't produce result sets. |
| `-f`, `--file <file>` | Read SQL query from file instead of command line |
| `-v`, `--verbose` | Print `Loaded <n> rows in <t>s` to stderr after loading (always on TTY; forced with flag) |
| `-s`, `--silent` | Suppress `Loaded <n> rows in <t>s` and the progress counter from stderr unconditionally. Cannot be combined with `-v`/`--verbose` |
| `--completions <shell>` | Generate shell completion script for `bash`, `zsh`, or `fish` to stdout |
| `-h`, `--help` | Show usage help and exit |
| `-V`, `--version` | Print version and exit |
| `--` | End of options — treat all remaining arguments as files or query |

After loading, `sql-pipe` prints `Loaded <n> rows in <t>s` to stderr whenever stderr is a TTY (interactive terminal). The message is suppressed in scripts and pipes to keep them noise-free. Use `-v` / `--verbose` to force it regardless of TTY, or `-s` / `--silent` to suppress it unconditionally (e.g. when stderr is a TTY but you want clean output):

```sh
$ cat sales.csv | sql-pipe --verbose 'SELECT region, SUM(revenue) FROM t GROUP BY region'
# stderr: Loaded 42,317 rows in 1.2s
```

When stderr is a TTY and the input exceeds 10,000 rows, a running counter updates in place on stderr during loading:

```
Loading... 10,000 rows
Loading... 20,000 rows
...
Loaded 42,317 rows in 1.2s
```

When `--max-rows` is set, the total limit is shown alongside the current count:

```
Loading... 10,000 / 100,000 rows
```

The counter is suppressed in pipes and scripts (zero overhead when stderr is not a TTY). The count uses thousands separators (`42,317` not `42317`). It is always written to stderr so stdout remains clean for piping.

### Exit Codes

| Code | Meaning |
|------|----------|
| `0` | Success |
| `1` | Usage error (missing query, bad arguments) |
| `2` | CSV parse error (with 1-based row number) |
| `3` | SQL error (with sqlite3 error message, available columns, and a "did you mean?" hint when applicable) |

All error messages are prefixed with `error:` and written to stderr.

On SQL error, `sql-pipe` also prints the list of columns available in table `t` and,
when the unknown identifier closely matches a column name (edit distance ≤ 2), a hint:

```
error: no such column: amout
  table "t" has columns: id, amount, region
  hint: did you mean "amount"?
```

## Recipes

**Multi-file join:**

```sh
$ sql-pipe orders.csv customers.csv \
    'SELECT c.name, SUM(o.amount) as total
     FROM orders o JOIN customers c ON o.cust_id = c.id
     GROUP BY c.name ORDER BY total DESC'
```

**Top N rows by a column:**

```sh
$ cat sales.csv | sql-pipe 'SELECT product, revenue FROM t ORDER BY revenue DESC LIMIT 10'
```

**Deduplicate rows:**

```sh
$ cat contacts.csv | sql-pipe 'SELECT DISTINCT email FROM t'
```

**Find rows with missing values:**

```sh
$ cat users.csv | sql-pipe 'SELECT * FROM t WHERE email = "" OR email IS NULL'
```

**Date range filter:**

```sh
$ cat logs.csv | sql-pipe 'SELECT * FROM t WHERE ts >= "2024-01-01" AND ts < "2024-02-01"'
```

Date columns are auto-detected and stored as ISO 8601 text, so comparison operators and `strftime()` / `julianday()` work without any preprocessing.

**Compute a derived column:**

```sh
$ cat products.csv | sql-pipe 'SELECT name, price, ROUND(price * 0.9, 2) as discounted FROM t'
```

**Pivot-like aggregation with conditional sums:**

```sh
$ cat orders.csv | sql-pipe 'SELECT region, SUM(CASE WHEN status="paid" THEN amount ELSE 0 END) as paid, SUM(CASE WHEN status="refunded" THEN amount ELSE 0 END) as refunded FROM t GROUP BY region'
```

**Quick data profiling with --stats:**

```sh
$ printf 'name,age\nAlice,30\nBob,25\nCarol,35\n' | sql-pipe --stats
┌────────┬─────────┬──────────┬─────┬─────┬──────┐
│ column │ type    │ non-null │ min │ max │ mean │
├────────┼─────────┼──────────┼─────┼─────┼──────┤
│ age    │ INTEGER │        3 │ 25  │ 35  │ 30.0 │
│ name   │ TEXT    │        3 │ Alice│Carol│      │
└────────┴─────────┴──────────┴─────┴─────┴──────┘
```

Same as running `SELECT MIN(col), MAX(col), AVG(col), COUNT(*)` per column — but in one command.

### Inspect data without queries (--inspect)

```sh
# List column names
$ sql-pipe --inspect columns data.csv
id
name
age

# With verbose: show inferred types
$ sql-pipe --inspect columns -v data.csv
id INTEGER
name TEXT
age INTEGER

# Validate input (parse check)
$ sql-pipe --inspect validate data.csv
OK: 1000 rows, 5 columns (id INTEGER, name TEXT, age INTEGER, ...)

# Sample first 5 rows with schema
$ sql-pipe --inspect sample 5 data.csv
# id INTEGER
# name TEXT
# age INTEGER
id,name,age
1,Alice,30
2,Bob,25
3,Carol,35
4,David,40
5,Eve,28

# Per-column statistics
$ sql-pipe --inspect stats data.csv
┌────────┬─────────┬──────────┬─────┬─────┬──────┐
│ column │ type    │ non-null │ min │ max │ mean │
├────────┼─────────┼──────────┼─────┼─────┼──────┤
│ age    │ INTEGER │        3 │ 25  │ 35  │ 30.0 │
│ name   │ TEXT    │        3 │ Alice│Carol│      │
└────────┴─────────┴──────────┴─────┴─────┴──────┘

# Inferred CREATE TABLE DDL
$ sql-pipe --inspect schema data.csv
CREATE TABLE t (id INTEGER, name TEXT, age INTEGER);
```

All `--inspect` modes support `--delimiter`, `--tsv`, `--no-type-inference`, `-I`/`--input-format` (csv, tsv, json, ndjson, yaml, xml, parquet). `--inspect sample` implies `--header`. `--inspect sample` and `--inspect stats` are mutually exclusive with `--json` output.

### Interactive REPL with --repl

```sh
$ sql-pipe --repl sales.csv
```

Loads the file once into SQLite, then enters an interactive prompt:

```
Loaded 12,543 rows
Entering interactive mode. Type .exit, .quit, Ctrl-D, or Ctrl-C to quit.
sql> SELECT region, SUM(revenue) FROM sales GROUP BY region;
+--------+-------------+
| region | SUM(revenue)|
+--------+-------------+
| APAC   | 2345999.00  |
| EMEA   | 3123400.00  |
| NA     | 1890234.00  |
+--------+-------------+
sql> .exit
```

Output respects `-O`/`--json`/`--table` flags. No history persistence (no arrow-key history). Compatible with `--save`/`--disk`. Pipe scripts non-interactively with `--no-stdin`:

```sh
$ printf 'SELECT 1+1;\n.exit\n' | sql-pipe --repl --no-stdin
2
```

**Dot commands:** `.help`, `.tables`, `.schema [table]`, `.read <file>`. **Multi-line queries:** end lines with Enter, finish with `;`. Empty line in multi-line mode executes the accumulated query.

### Debug query performance with --explain

```sh
$ printf 'region,amount\nEast,100\nWest,200\nNorth,300\n' | sql-pipe --explain 'SELECT region, SUM(amount) FROM t GROUP BY region'
```

Prints the SQLite execution plan to stderr (prefixed with `QUERY PLAN:`) before running the query:

```
QUERY PLAN: SCAN t
```

The actual query results still go to stdout:

```
East,100
North,300
West,200
```

Useful for understanding how SQLite handles complex JOINs, aggregations, and subqueries — plan goes to stderr so stdout stays machine-parseable.

### Verify result integrity with --checksum

```sh
$ printf 'name,age\nAlice,30\nBob,25\n' | sql-pipe --checksum 'SELECT name FROM t ORDER BY age'
checksum: 081a774cb12f7bd5ea746c3b516da7b5bb8d6e7f62a30c6416f1e79c8958aef7
Bob
Alice
```

The SHA-256 hash of the result set is printed to stderr as `checksum: <hash>`. The hash covers only stdout output (the result set), so it works correctly with `--output`, `--verbose`, `--explain`, and other flags that write to stderr. Skipped in inspect modes (`--columns`, `--validate`, `--sample`, `--stats`, `--schema`).

> **Note:** The entire result set is buffered in memory to compute the checksum. For very large result sets, this may consume significant RAM. Add a `LIMIT` clause to your query to bound the result size. `--max-rows` caps input rows, not output rows. Note: `--checksum` defeats `--disk` — the result set always buffers in RAM regardless of database backing.

## Real-world examples

These run against live public URLs — no local files needed.

**La Liga: all-time home wins (1929–present)**

The [engsoccerdata](https://github.com/jalapic/engsoccerdata) dataset covers
Spanish first-division football since the inaugural season:

```sh
$ sql-pipe --url https://raw.githubusercontent.com/jalapic/engsoccerdata/master/data-raw/spain.csv \
  'SELECT home AS team, COUNT(*) AS wins
            FROM t WHERE CAST(hgoal AS INTEGER) > CAST(vgoal AS INTEGER) AND tier=1
            GROUP BY home ORDER BY wins DESC LIMIT 8'
Real Madrid,1174
FC Barcelona,1163
Atletico Madrid,956
Athletic Bilbao,942
Valencia CF,917
Sevilla FC,815
Espanyol Barcelona,777
Real Sociedad,721
```

**La Liga: highest-scoring seasons as JSON**

Same dataset, different angle — output as JSON for downstream tools:

```sh
$ sql-pipe --url https://raw.githubusercontent.com/jalapic/engsoccerdata/master/data-raw/spain.csv --json \
    'SELECT Season, COUNT(*) AS matches,
            ROUND(CAST(SUM(CAST(hgoal AS INTEGER)+CAST(vgoal AS INTEGER)) AS REAL)/COUNT(*),2) AS avg_goals
     FROM t WHERE tier=1 GROUP BY Season ORDER BY avg_goals DESC LIMIT 5'
[{"Season":1929,"matches":90,"avg_goals":4.67},{"Season":1932,"matches":90,"avg_goals":4.44},...]
```

**Gapminder: countries with the highest life expectancy (2007)**

This stable 7 KB CSV has country, continent, population, life expectancy, and
GDP-per-capita columns. Find countries with the highest life expectancy:

```sh
$ sql-pipe --url https://raw.githubusercontent.com/plotly/datasets/master/gapminder2007.csv \
  'SELECT country, ROUND(lifeExp,1) AS life_expectancy,
          ROUND(gdpPercap) AS gdp_per_capita
   FROM t ORDER BY life_expectancy DESC LIMIT 8'
Japan,82.6,31656.0
"Hong Kong, China",82.2,39725.0
Iceland,81.8,36181.0
Switzerland,81.7,37506.0
Australia,81.2,34435.0
Spain,80.9,28821.0
Sweden,80.9,33860.0
Canada,80.7,36319.0
```

**Gapminder: continental overview — two-pass query**

First pass aggregates each continent. `-H` sends headers to second pass, which
sorts population numerically:

```sh
$ DATA=https://raw.githubusercontent.com/plotly/datasets/master/gapminder2007.csv
$ sql-pipe --url "$DATA" -H 'SELECT continent,
                         COUNT(*) AS countries,
                         ROUND(SUM(pop)/1000000.0,1) AS population_millions,
                         ROUND(AVG(lifeExp),1) AS avg_life_expectancy
                  FROM t GROUP BY continent' \
  | sql-pipe 'SELECT continent, countries, population_millions, avg_life_expectancy
              FROM t ORDER BY CAST(population_millions AS REAL) DESC'
Asia,33,3812.0,70.7
Africa,52,929.5,54.8
Americas,25,898.9,73.6
Europe,30,586.1,77.6
Oceania,2,24.5,80.7
```

**JSON: fuel efficiency by origin**

[Vega datasets](https://github.com/vega/vega-datasets) provides this 100 KB
JSON array, which `sql-pipe` consumes directly with `-I json`:

```sh
$ sql-pipe --url https://raw.githubusercontent.com/vega/vega-datasets/main/data/cars.json -I json \
  'SELECT Origin, COUNT(*) AS cars,
          ROUND(AVG("Miles_per_Gallon"),1) AS avg_mpg
   FROM t WHERE "Miles_per_Gallon" IS NOT NULL
   GROUP BY Origin ORDER BY avg_mpg DESC'
Japan,79,30.5
Europe,70,27.9
USA,249,20.1
```

**Live weather: 7-day Madrid forecast**

[Open-Meteo](https://open-meteo.com) serves free forecasts as JSON. The daily
arrays need transposing into objects — `jq` handles that, then `-I ndjson` loads
the result:

```sh
$ curl -s "https://api.open-meteo.com/v1/forecast?latitude=40.4168&longitude=-3.7038&daily=temperature_2m_max,temperature_2m_min,precipitation_sum&timezone=Europe%2FMadrid&forecast_days=7" \
  | jq -c '.daily
    | [.time, .temperature_2m_max, .temperature_2m_min, .precipitation_sum]
    | transpose
    | .[] | {day:.[0], max_c:.[1], min_c:.[2], rain_mm:.[3]}' \
  | sql-pipe -I ndjson 'SELECT day, max_c, min_c, rain_mm FROM t ORDER BY day'
2026-05-01,24.3,11.8,0.0
2026-05-02,19.2,14.5,3.9
2026-05-03,20.5,12.5,7.0
2026-05-04,19.3,11.3,0.2
2026-05-05,16.9,9.1,1.8
2026-05-06,19.7,7.3,0.0
2026-05-07,19.6,10.7,2.1
```

**La Liga: season lengths reveal COVID and the World Cup**

The same [engsoccerdata](https://github.com/jalapic/engsoccerdata) dataset has a
`Date` column in `YYYY-MM-DD` format. `sql-pipe` auto-detects it as `DATE` and
stores it as ISO 8601 text, so `julianday()` works directly — no preprocessing:

```sh
$ sql-pipe --url https://raw.githubusercontent.com/jalapic/engsoccerdata/master/data-raw/spain.csv \
  'SELECT Season,
                 MIN(Date) AS start,
                 MAX(Date) AS end,
                 CAST(julianday(MAX(Date)) - julianday(MIN(Date)) AS INTEGER) AS days
          FROM t WHERE tier=1 AND Season BETWEEN 2018 AND 2022
          GROUP BY Season ORDER BY Season'
2018,2018-08-17,2019-05-19,275
2019,2019-08-16,2020-07-19,338
2020,2020-09-12,2021-05-23,253
2021,2021-08-13,2022-05-22,282
2022,2022-08-12,2023-06-04,296
```

The 2019–20 season spans 338 days: COVID suspended play in March 2020 and pushed
the final round to July. The 2022–23 season runs 296 days due to the November
World Cup break. A normal season is ~275 days.

## How it works

Each run opens a fresh `:memory:` SQLite database. The header row drives a `CREATE TABLE t (...)` with types inferred from the first 100 rows — `INTEGER`, `REAL`, `DATE`, `DATETIME`, or `TEXT`. Date variants use TEXT affinity so ISO 8601 string semantics are preserved and all SQLite date functions work correctly. Rows are loaded in a single transaction via a prepared `INSERT` statement, then `sqlite3_exec` runs your query and prints rows one by one.

The database is in-memory by default and vanishes when the process exits. Use `--save <file>` to persist it to disk for later queries with `sqlite3`, or `--disk` for a file-backed temporary database when processing datasets larger than available RAM.

## Limitations

- **File format auto-detection** is based on file extension. Files without a recognized extension (`.csv`, `.tsv`, `.json`, `.ndjson`, `.yaml`, `.yml`, `.xml`, `.parquet`) default to CSV. Use `-I` to override.
- **Parquet column types** are mapped from physical types: INT32/INT64→INTEGER, FLOAT/DOUBLE→REAL, BYTE_ARRAY→TEXT, BOOLEAN→INTEGER (0/1). Logical types (DATE, TIMESTAMP, DECIMAL) are converted to their ISO/text representation. Nested types (LIST, MAP, STRUCT) are not supported.

## Related

- **[q](https://harelba.github.io/q/)** — Python-based SQL on tabular data. Similar concept, but requires Python runtime. Better if you're already in a Python environment or need Python-specific integrations.
- **[trdsql](https://github.com/noborus/trdsql)** — Go alternative with broader format support (LTSV, TBLN) and more output options. Better if you need formats beyond CSV/JSON/NDJSON/YAML/XML or want more output formatting choices.
- **[sqlite-utils](https://sqlite-utils.datasette.io/)** — better if you need persistent databases, schema management, or Python scripting. sql-pipe is designed for one-shot queries on ephemeral in-memory data.
