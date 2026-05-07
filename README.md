# sql-pipe

[![CI](https://github.com/vmvarela/sql-pipe/actions/workflows/ci.yml/badge.svg)](https://github.com/vmvarela/sql-pipe/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/vmvarela/sql-pipe)](https://github.com/vmvarela/sql-pipe/releases/latest)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

`sql-pipe` reads CSV, JSON, or NDJSON from stdin, loads it into an in-memory SQLite database, runs a SQL query, and prints the results. No server, no schema files, no setup.

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

Replace `VERSION` with the release version (e.g. `0.3.0`) and `amd64` with your architecture (`arm64`, `arm7`, or `386`).

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

Replace `VERSION` with the release version (e.g. `0.3.0`) and `amd64` with your architecture (`arm64`).

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

Replace `VERSION` with the release version (e.g. `0.3.0`) and `amd64` with your architecture (`arm64`).

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
scoop bucket add vmvarela https://github.com/vmvarela/scoop-bucket
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

The input comes from stdin. For CSV and TSV, the first row must be a header — those column names become the schema for a table called `t`. Results go to stdout as comma-separated values by default.

```sh
$ printf 'name,age\nAlice,30\nBob,25\nCarol,35' | sql-pipe 'SELECT * FROM t'
Alice,30
Bob,25
Carol,35
```

For JSON and NDJSON input, pass `-I json` (reads an array of objects) or `-I ndjson` (one object per line). Column names are taken from the keys of the first object:

```sh
$ printf '[{"name":"Alice","score":95},{"name":"Bob","score":72}]' \
  | sql-pipe -I json 'SELECT name, score FROM t WHERE score > 80'
Alice,95
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

Chain queries by piping back in — useful for two-pass aggregations. Pass `-H` to the first call so the second one sees column names:

```sh
$ cat events.csv \
  | sql-pipe -H 'SELECT user_id, COUNT(*) as n FROM t GROUP BY user_id' \
  | sql-pipe 'SELECT * FROM t WHERE n > 100'
```

### Flags

| Flag | Description |
|------|-------------|
| `-d`, `--delimiter <char>` | Input field delimiter (single character, default `,`) |
| `--tsv` | Alias for `--delimiter '\t'` |
| `-I`, `--input-format <fmt>` | Input format: `csv` (default), `tsv`, `json`, `ndjson` |
| `-O`, `--output-format <fmt>` | Output format: `csv` (default), `tsv`, `json`, `ndjson` |
| `--no-type-inference` | Treat all columns as TEXT (skip auto-detection) |
| `-H`, `--header` | Print column names as the first output row |
| `--json` | Alias for `--output-format json` (mutually exclusive with `-H`) |
| `--max-rows <n>` | Stop if more than `n` data rows are read (exit 1) |
| `--columns` | Read the CSV header row, print each column name on its own line, and exit 0. With `-v`/`--verbose`, also shows the inferred type per column (`name INTEGER`). Respects `--delimiter` and `--tsv`. Mutually exclusive with a query argument. |
| `--output <file>` | Write results to the given file instead of stdout. Creates or overwrites the file. Exits 1 if the file cannot be created. |
| `-v`, `--verbose` | Print `Loaded <n> rows in <t>s` to stderr after loading (always on TTY; forced with flag) |
| `-s`, `--silent` | Suppress `Loaded <n> rows in <t>s` and the progress counter from stderr unconditionally. Cannot be combined with `-v`/`--verbose` |
| `-h`, `--help` | Show usage help and exit |
| `-V`, `--version` | Print version and exit |

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

## Real-world examples

These run against live public URLs — no local files needed.

**La Liga: all-time home wins (1929–present)**

The [engsoccerdata](https://github.com/jalapic/engsoccerdata) dataset covers
Spanish first-division football since the inaugural season:

```sh
$ curl -s https://raw.githubusercontent.com/jalapic/engsoccerdata/master/data-raw/spain.csv \
  | sql-pipe 'SELECT home AS team, COUNT(*) AS wins
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
$ curl -s https://raw.githubusercontent.com/jalapic/engsoccerdata/master/data-raw/spain.csv \
  | sql-pipe --json \
    'SELECT Season, COUNT(*) AS matches,
            ROUND(CAST(SUM(CAST(hgoal AS INTEGER)+CAST(vgoal AS INTEGER)) AS REAL)/COUNT(*),2) AS avg_goals
     FROM t WHERE tier=1 GROUP BY Season ORDER BY avg_goals DESC LIMIT 5'
[{"Season":1929,"matches":90,"avg_goals":4.67},{"Season":1932,"matches":90,"avg_goals":4.44},...]
```

**OWID: countries by solar electricity share (2023)**

[Our World in Data](https://github.com/owid/energy-data) publishes annual
energy statistics for 200+ countries. Find who leads on solar:

```sh
$ curl -s https://raw.githubusercontent.com/owid/energy-data/refs/heads/master/owid-energy-data.csv \
  | sql-pipe 'SELECT country, ROUND(solar_share_elec,1) AS solar_pct
              FROM t WHERE year=2023 AND solar_share_elec IS NOT NULL
                AND iso_code NOT LIKE "%OWID%"
              ORDER BY solar_pct DESC LIMIT 8'
Cook Islands,50.0
Palestine,40.0
Namibia,27.0
Kiribati,25.0
Lebanon,22.3
Luxembourg,20.6
Chile,20.1
El Salvador,20.1
```

**OWID: wind + solar combined — two-pass query**

Add wind and solar in a first pass, then filter above 30% in a second.
`-H` passes column names through to the next stage. Spain sits at 40%:

```sh
$ ENERGY=https://raw.githubusercontent.com/owid/energy-data/refs/heads/master/owid-energy-data.csv
$ curl -s "$ENERGY" \
  | sql-pipe -H 'SELECT country,
                        ROUND(solar_share_elec,1) AS solar,
                        ROUND(wind_share_elec,1)  AS wind,
                        ROUND(solar_share_elec+wind_share_elec,1) AS total
                 FROM t WHERE year=2023 AND iso_code NOT LIKE "%OWID%"
                   AND solar_share_elec IS NOT NULL AND wind_share_elec IS NOT NULL' \
  | sql-pipe 'SELECT country, solar, wind, total FROM t
              WHERE CAST(total AS REAL) >= 30 ORDER BY total DESC LIMIT 10'
Denmark,10.8,57.2,68.0
Lithuania,13.0,47.9,60.9
Luxembourg,20.6,35.5,56.0
Cook Islands,50.0,0.0,50.0
Netherlands,16.3,24.6,41.0
Uruguay,3.8,37.1,41.0
Greece,18.2,22.5,40.7
Spain,17.4,23.0,40.4
Germany,12.6,27.7,40.3
Palestine,40.0,0.0,40.0
```

**REST API: European population density**

[restcountries.com](https://restcountries.com) returns a JSON array. Reshape
with `jq` into NDJSON (one object per line) and query directly with `-I ndjson`:

```sh
$ curl -s https://restcountries.com/v3.1/region/europe \
  | jq -c '.[] | {country: .name.common, pop: .population, area: .area}' \
  | sql-pipe -I ndjson \
    'SELECT country, pop, area, ROUND(CAST(pop AS REAL)/area,1) AS density
     FROM t WHERE area > 0 ORDER BY density DESC LIMIT 8'
Monaco,38423,2.02,19021.3
Gibraltar,38000,6.0,6333.3
Malta,574250,316.0,1817.2
Vatican City,882,0.49,1800.0
Jersey,103267,116.0,890.2
Guernsey,64781,78.0,830.5
San Marino,34132,61.0,559.5
Netherlands,18100436,41865.0,432.4
```

**Live weather: 7-day Madrid forecast**

[Open-Meteo](https://open-meteo.com) serves free forecasts as JSON. The daily
arrays need transposing into objects — `jq` handles that, then `-I ndjson` loads
the result:

```sh
$ curl -s "https://api.open-meteo.com/v1/forecast?latitude=40.4168&longitude=-3.7038\
&daily=temperature_2m_max,temperature_2m_min,precipitation_sum\
&timezone=Europe%2FMadrid&forecast_days=7" \
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

## How it works

Each run opens a fresh `:memory:` SQLite database. The header row drives a `CREATE TABLE t (...)` with all columns as `TEXT`. Rows are loaded in a single transaction via a prepared `INSERT` statement, then `sqlite3_exec` runs your query and prints rows one by one.

The database never touches disk and vanishes when the process exits. No state, no cleanup.

## Limitations

- **Single table per invocation.** For joins, use chained `sql-pipe` calls or a `WITH` CTE.

## Related

- **[q](https://harelba.github.io/q/)** — similar concept in Python; handles quoted CSV fields and more formats. Better if you're already in a Python environment.
- **[trdsql](https://github.com/noborus/trdsql)** — Go alternative with multi-format support (JSON, LTSV) and output formatting. Better if you need non-CSV inputs.
- **[sqlite-utils](https://sqlite-utils.datasette.io/)** — better if you need persistent databases, schema management, or Python scripting.
