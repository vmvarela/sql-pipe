# sql-pipe

[![CI](https://github.com/vmvarela/sql-pipe/actions/workflows/ci.yml/badge.svg)](https://github.com/vmvarela/sql-pipe/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/vmvarela/sql-pipe)](https://github.com/vmvarela/sql-pipe/releases/latest)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

`sql-pipe` reads CSV from stdin, loads it into an in-memory SQLite database, runs a SQL query, and prints the results as CSV. No server, no schema files, no setup.

It exists because `awk` is cryptic, spinning up a Python interpreter for a one-liner feels wrong, and `sqlite3 :memory:` takes four commands before you can query anything. If you know SQL and work with CSV in the terminal, this is the tool you've been reaching for.

```sh
$ curl -s https://example.com/data.csv | sql-pipe 'SELECT region, SUM(revenue) FROM t GROUP BY region ORDER BY 2 DESC'
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

**Debian / Ubuntu (.deb package):**

```sh
wget https://github.com/vmvarela/sql-pipe/releases/latest/download/sql-pipe_VERSION_amd64.deb
sudo dpkg -i sql-pipe_VERSION_amd64.deb
```

Replace `VERSION` with the release version (e.g. `0.2.0`) and `amd64` with your architecture (`arm64`, `armhf`, or `386`).

**Fedora / RHEL / openSUSE (.rpm package):**

```sh
sudo rpm -i https://github.com/vmvarela/sql-pipe/releases/latest/download/sql-pipe-VERSION-1.x86_64.rpm
```

Replace `VERSION` with the release version (e.g. `0.2.0`) and `x86_64` with your architecture (`aarch64`).

**Alpine Linux (.apk package):**

```sh
wget https://github.com/vmvarela/sql-pipe/releases/latest/download/sql-pipe_VERSION_x86_64.apk
sudo apk add --allow-untrusted sql-pipe_VERSION_x86_64.apk
```

Replace `VERSION` with the release version (e.g. `0.2.0`) and `x86_64` with your architecture (`aarch64`).

**Arch Linux (AUR):** install with your preferred AUR helper:

```sh
yay -S sql-pipe
# or
paru -S sql-pipe
```

**Nix / NixOS:**

```sh
# Run without installing
nix run github:vmvarela/sql-pipe -- 'SELECT * FROM t'

# Install to profile
nix profile install github:vmvarela/sql-pipe

# Non-flake
nix-env -if https://github.com/vmvarela/sql-pipe/archive/master.tar.gz
```

**Windows (Chocolatey):**

```powershell
choco install sql-pipe
```

**Windows (WinGet):**

```powershell
winget install vmvarela.sql-pipe
```

**Windows (Scoop):**

```powershell
scoop bucket add sql-pipe https://github.com/vmvarela/scoop-sql-pipe
scoop install sql-pipe
```

To build from source (requires [Zig 0.15+](https://ziglang.org/download/)):

```sh
git clone https://github.com/vmvarela/sql-pipe
cd sql-pipe
mkdir -p lib
curl -fsSL https://www.sqlite.org/2025/sqlite-amalgamation-3490100.zip -o sqlite.zip
unzip -j sqlite.zip '*/sqlite3.c' '*/sqlite3.h' -d lib/
zig build -Dbundle-sqlite=true -Doptimize=ReleaseSafe
```

Binary lands at `./zig-out/bin/sql-pipe`. SQLite is compiled from the official amalgamation — no system dependencies.

## Usage

The CSV comes from stdin. The first row must be a header — those column names become the schema for a table called `t`. Results go to stdout as comma-separated values.

```sh
$ printf 'name,age\nAlice,30\nBob,25\nCarol,35' | sql-pipe 'SELECT * FROM t'
Alice,30
Bob,25
Carol,35
```

Columns are auto-detected as `INTEGER`, `REAL`, or `TEXT` based on the first 100 rows. Use `--no-type-inference` to force all columns to `TEXT`:

```sh
$ cat orders.csv | sql-pipe 'SELECT COUNT(*), AVG(amount) FROM t WHERE status = "paid"'
142,87.35
```

Column names with spaces work — quote them in SQL:

```sh
$ cat report.csv | sql-pipe 'SELECT "first name", "last name" FROM t WHERE "dept id" = "42"'
```

Use a custom input delimiter with `-d` / `--delimiter` (single character), or `--tsv` for tab-separated files:

```sh
$ cat data.psv | sql-pipe -d '|' 'SELECT * FROM t'
$ cat data.tsv | sql-pipe --tsv 'SELECT * FROM t'
# equivalent:
$ cat data.tsv | sql-pipe --delimiter '\t' 'SELECT * FROM t'
```

Output results as a JSON array of objects with `--json`:

```sh
$ printf 'name,age\nAlice,30\nBob,25' | sql-pipe --json 'SELECT * FROM t'
[{"name":"Alice","age":30},{"name":"Bob","age":25}]
```

`--json` is mutually exclusive with `-H`/`--header`. It can be combined with `-d`/`--delimiter` and `--tsv` to read non-comma-separated input.

Chain queries by piping back in — useful for two-pass aggregations:

```sh
$ cat events.csv \
  | sql-pipe 'SELECT user_id, COUNT(*) as n FROM t GROUP BY user_id' \
  | sql-pipe 'SELECT * FROM t WHERE n > 100'
```

### Flags

| Flag | Description |
|------|-------------|
| `-d`, `--delimiter <char>` | Input field delimiter (single character, default `,`) |
| `--tsv` | Alias for `--delimiter '\t'` |
| `--no-type-inference` | Treat all columns as TEXT (skip auto-detection) |
| `-H`, `--header` | Print column names as the first output row |
| `--json` | Output results as a JSON array of objects (mutually exclusive with `-H`) |
| `--max-rows <n>` | Stop if more than `n` data rows are read (exit 1) |
| `--columns` | Read the CSV header row, print each column name on its own line, and exit 0. With `-v`/`--verbose`, also shows the inferred type per column (`name INTEGER`). Respects `--delimiter` and `--tsv`. Mutually exclusive with a query argument. |
| `--output <file>` | Write results to the given file instead of stdout. Creates or overwrites the file. Exits 1 if the file cannot be created. |
| `-v`, `--verbose` | Print `Loaded <n> rows in <t>s` to stderr after loading (always on TTY; forced with flag) |
| `-h`, `--help` | Show usage help and exit |
| `-V`, `--version` | Print version and exit |

After loading, `sql-pipe` prints `Loaded <n> rows in <t>s` to stderr whenever stderr is a TTY (interactive terminal). The message is suppressed in scripts and pipes to keep them noise-free. Use `-v` / `--verbose` to force it regardless of TTY:

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

**Date range filter (dates stored as text):**

```sh
$ cat logs.csv | sql-pipe 'SELECT * FROM t WHERE ts >= "2024-01-01" AND ts < "2024-02-01"'
```

**Compute a derived column:**

```sh
$ cat products.csv | sql-pipe 'SELECT name, price, ROUND(price * 0.9, 2) as discounted FROM t'
```

**Pivot-like aggregation with conditional sums:**

```sh
$ cat orders.csv | sql-pipe 'SELECT region, SUM(CASE WHEN status="paid" THEN amount ELSE 0 END) as paid, SUM(CASE WHEN status="refunded" THEN amount ELSE 0 END) as refunded FROM t GROUP BY region'
```

## How it works

Each run opens a fresh `:memory:` SQLite database. The header row drives a `CREATE TABLE t (...)` with all columns as `TEXT`. Rows are loaded in a single transaction via a prepared `INSERT` statement, then `sqlite3_exec` runs your query and prints rows one by one.

The database never touches disk and vanishes when the process exits. No state, no cleanup.

## Limitations

- **Single table per invocation.** For joins, use chained `sql-pipe` calls or a `WITH` CTE.

## Related

- **[q](https://harelba.github.io/q/)** — similar concept in Python; handles quoted CSV fields and more formats. Better if you're already in a Python environment.
- **[trdsql](https://github.com/noborus/trdsql)** — Go alternative with multi-format support (JSON, LTSV) and output formatting. Better if you need non-CSV inputs.
- **[sqlite-utils](https://sqlite-utils.datasette.io/)** — better if you need persistent databases, schema management, or Python scripting.
