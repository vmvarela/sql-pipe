sql-pipe(1)

NAME
	sql-pipe - Execute SQL queries on CSV/JSON/XML data from stdin or files

SYNOPSIS
	*sql-pipe* [OPTIONS] [<file>...] <query>
	*sql-pipe* [OPTIONS] <query>
	*sql-pipe* -f <file> [OPTIONS] [<file>...]
	*sql-pipe* -f <file> [OPTIONS]
	*sql-pipe* --columns [OPTIONS] [<file>]
	*sql-pipe* --sample [<n>] [OPTIONS] [<file>]
	*sql-pipe* --stats [OPTIONS] [<file>]
	*sql-pipe* --schema [OPTIONS] [<file>...]
	*sql-pipe* --explain [OPTIONS] [<file>] <query>

DESCRIPTION
	sql-pipe reads CSV, JSON, NDJSON, or XML data from standard input and/or
	file arguments, loads it into an in-memory SQLite database, executes the
	provided SQL query, and prints the results as CSV (or JSON/XML when
	requested) to standard output.

	When reading from stdin, data is loaded into a table named *t*. When files
	are passed as positional arguments, each file becomes a table named after
	its basename without extension (e.g., *orders.csv* becomes table *orders*).
	Stdin and file arguments can be combined — stdin is always table *t*.

	Input format for files is auto-detected from the file extension (*.csv*,
	*.tsv*, *.json*, *.ndjson*, *.xml*). Unrecognized or missing extensions
	default to CSV. Use *-I* to override auto-detection (e.g., when a
	TSV file has a *.txt* extension).

	This tool is useful for quick data transformations, filtering, grouping,
	aggregations, and multi-file joins without manual SQL database setup.

	All input columns are automatically loaded into the table with names derived
	from the CSV header row (or JSON keys). By default, column types (TEXT,
	INTEGER, REAL, DATE, DATETIME) are inferred from the first 100 rows of data.
	DATE and DATETIME values are normalized to ISO 8601 on insert, enabling
	SQLite date functions (*date()*, *strftime()*, *julianday()*) to work
	directly on those columns. Use *--no-type-inference* to disable this
	behavior and treat all columns as TEXT.

	By default, input fields are parsed as comma-separated values. Use
	*--delimiter* (or *-d*) to parse other delimiters (1–8 characters), or *--tsv*
	for tab-separated input.

	Exit codes follow a structured convention for scripting integration (see EXIT CODES
	section).

OPTIONS
	*-d, --delimiter* <string>
		Use a custom input field delimiter (1–8 bytes) instead of comma.
		Examples: *-d '|'* for pipe-separated files, *--delimiter '\\t'* for
		tab-separated files, *-d '||'* for double-pipe-separated files.
		Produces a usage error if the value is empty or longer than 8 bytes.

	*--tsv*
		Alias for *--delimiter '\\t'*. Parses tab-separated input.

	*-I, --input-format* <fmt>
		Set the input format explicitly: *csv* (default), *tsv*, *json*,
		*ndjson*, or *xml*. When set, overrides file extension auto-detection
		for all file arguments. Stdin always uses this value (no filename
		to inspect). Useful when a file has an ambiguous extension (*.txt*,
		*.dat*) or no extension at all.

	*-O, --output-format* <fmt>
		Set the output format: *csv* (default), *tsv*, *json*, *ndjson*,
		*xml*, *markdown* (alias: *md*), or *sql*.

	*--sql-table* <name>
		Target table name for *-O sql* INSERT output (default: *t*).

	*--no-type-inference*
		Treat all columns as TEXT. Skips automatic type detection and uses plain
		TEXT affinity for all columns in the SQLite table. This can improve
		performance on very large datasets if type inference is not needed.

	*-H, --header*
		Print a header row with column names as the first line of output. Column
		names are taken from the SQL column alias or original name. The output
		remains valid CSV that can be piped back into sql-pipe. Header output is
		off by default. Cannot be combined with *--json*.

	*--json*
		Output results as a JSON array of objects instead of CSV. Each row
		becomes a JSON object with column names as keys and typed values (string,
		number, or null). Mutually exclusive with *--delimiter*, *--tsv*, and
		*--header*.

	*--max-rows* <n>
		Stop reading input after inserting <n> data rows and exit with
		code 1 and an error message. Use this to guard against
		accidentally piping extremely large files into memory.

	*-v, --verbose*
		Print "Loaded <n> rows in <t>s" to standard error after all rows
		are inserted. The message is shown automatically when stderr is a
		TTY; this flag forces it unconditionally (e.g. in scripts or
		pipes). Cannot be combined with *-s* / *--silent*.

	*-s, --silent*
		Suppress the "Loaded <n> rows in <t>s" message and the loading
		progress counter from standard error unconditionally, even when
		stderr is a TTY. Useful for producing clean stderr in interactive
		terminals. Cannot be combined with *-v* / *--verbose*.

	*--xml-root* <name>
		Root element name used when reading or writing XML (default: *results*).
		The output document is wrapped in *<name>...</name>*. Also used as the
		expected root tag when parsing XML input.

	*--xml-row* <name>
		Row element name used when reading or writing XML (default: *row*).
		Each result row is emitted as *<name><col>value</col>...</name>*.

	*--validate*
		Parse the entire input without executing a SQL query. On success,
		prints a one-line summary to standard output:
		*OK: <n> rows, <m> columns (<col> <TYPE>, ...)* and exits 0.
		On parse error, prints the error message and exits 2. Compatible
		with *--delimiter*, *--tsv*, *--no-type-inference*, and
		*-I* / *--input-format* (csv, tsv, json, ndjson, xml). JSON, NDJSON,
		and XML columns are reported as TEXT. Mutually exclusive with a query
		argument.

	*--columns*
		Read the input header, print each column name on its own line to
		standard output, and exit with code 0. Supported for CSV, TSV,
		JSON, NDJSON, and XML input. When combined with *-v* / *--verbose*,
		also shows the inferred type (INTEGER, REAL, DATE, DATETIME, or TEXT) for each column
		(CSV/TSV only; other formats always show TEXT), using the first 100
		data rows for inference. Respects *--delimiter* and *--tsv*.
		Mutually exclusive with a query argument.

	*--sample* [<n>]
		Print a schema comment block to standard error and the first <n> data
		rows to standard output as delimited text (default: 10 rows if no value
		is given). The schema block lists each column name and its inferred
		type (INTEGER, REAL, DATE, DATETIME, or TEXT), each line prefixed with *#* so it
		is ignored by downstream CSV parsers. Column header is always printed as
		the first output row (implies *--header*). Type inference reads up to
		100 rows or <n> rows, whichever is larger, before emitting output.
		Compatible with *--delimiter* and *--tsv*. Mutually exclusive with
		*--json*, *--columns*, *--validate*, and a query argument. CSV and TSV
		input only.

	*--stats*
		Load input and print per-column statistics (column name, type,
		non-null count, min, max, mean) as a formatted table. Mean is blank
		for non-numeric columns. Compatible with *--delimiter*, *--tsv*,
		*--no-type-inference*, and *-I* / *--input-format* (csv, tsv, json,
		ndjson, xml). Mutually exclusive with a query argument, *--columns*,
		*--validate*, *--sample*, and *--output*.
		Alias: *--profile*.

	*--schema*
		Load input and print the inferred CREATE TABLE DDL to standard
		output. Each input file generates one DDL block; stdin uses table
		name *t*. No query is required. Compatible with *--delimiter*,
		*--tsv*, *--no-type-inference*, and *-I* / *--input-format* (csv,
		tsv, json, ndjson, xml). Mutually exclusive with a query argument,
		*--columns*, *--validate*, *--sample*, *--stats*, *--explain*,
		and *--output*.

	*--output* <file>
		Write results to <file> instead of standard output. Creates or
		overwrites the file. Compatible with all output modes (*--json*,
		*--header*, CSV). Exits with code 1 and an error message if the file
		cannot be created (bad path or insufficient permissions).

	*--explain*
		Before executing the SQL query, run *EXPLAIN QUERY PLAN* and print
		the execution plan to standard error. Each line is prefixed with
		*QUERY PLAN:* so stdout remains clean for piping. The actual query
		still executes normally and results go to stdout. Mutually exclusive
		with *--columns*, *--validate*, *--sample*, *--stats*, *--schema*, and *--output*.

	*--null-value* <string>
		Custom representation for SQL NULL values in CSV, TSV, and table
		output. By default, NULL values are printed as the string *NULL*.
		Pass an empty string (*--null-value ''*), *N/A*, or any other label.
		Has no effect on JSON output (JSON always outputs native *null*).

	*-f, --file* <file>
		Read the SQL query from <file> instead of the command line. When
		this flag is used, all positional arguments are treated as data
		files (no positional query is needed). Exits with code 1 and an
		error message if the file does not exist, cannot be read, or is
		empty.

	*-h, --help*
		Print the help message and exit with code 0.

	*-V, --version*
		Print the version number and exit with code 0.

	*--*
		End of options. All remaining arguments are treated as positional
		arguments (files or query), even if they start with a dash. Use this
		when a filename begins with *-*.

EXAMPLES
	Select all rows from stdin:

		$ cat people.csv | sql-pipe 'SELECT name, age FROM t'

	Output:++
	Alice,30++
	Bob,25

	Query a file directly (table named after basename):

		$ sql-pipe orders.csv 'SELECT * FROM orders WHERE amount > 100'

	Join two files:

		$ sql-pipe orders.csv customers.csv ++
		    'SELECT c.name, SUM(o.amount) FROM orders o ++
		     JOIN customers c ON o.cust_id = c.id GROUP BY c.name'

	Query a JSON file (format auto-detected from extension):

		$ sql-pipe data.json 'SELECT * FROM data WHERE score > 80'

	Override auto-detection when the extension is wrong:

		$ sql-pipe -I tsv data.txt 'SELECT * FROM data'

	Mix stdin (as table t) with a file argument:

		$ cat events.csv | sql-pipe users.csv ++
		    'SELECT * FROM t JOIN users ON t.uid = users.id'

	Read query from a file:

		$ sql-pipe -f analysis.sql orders.csv

	Combine -f with stdin:

		$ cat data.csv | sql-pipe -f analysis.sql

	Group data by region and sum revenue:

		$ cat sales.csv | sql-pipe 'SELECT region, SUM(revenue) FROM t GROUP BY region'

	Filter rows where age is greater than 25:

		$ sql-pipe 'SELECT name FROM t WHERE age > 25' < data.csv

	Include a header row in the output:

		$ cat data.csv | sql-pipe --header 'SELECT name, age FROM t'

	Pipe output with header back into sql-pipe:

		$ cat data.csv | sql-pipe -H 'SELECT \* FROM t' | sql-pipe 'SELECT name FROM t'

	Process data with type inference disabled:

		$ cat numbers.csv | sql-pipe --no-type-inference 'SELECT name, id FROM t WHERE id = "001"'

	Process pipe-separated input:

		$ cat data.psv | sql-pipe -d '|' 'SELECT \* FROM t'

	Process tab-separated input (TSV):

		$ cat data.tsv | sql-pipe --tsv 'SELECT \* FROM t'

	Output results as JSON:

		$ printf 'name,age\nAlice,30\nBob,25' | sql-pipe --json 'SELECT \* FROM t'

	Output:++
	[{"name":"Alice","age":30},{"name":"Bob","age":25}]

	Convert CSV to XML:

		$ printf 'name,age\nAlice,30\nBob,25' | sql-pipe -O xml 'SELECT \* FROM t'

	Output:++
	<?xml version="1.0" encoding="UTF-8"?>++
	<results>++
	<row><name>Alice</name><age>30</age></row>++
	<row><name>Bob</name><age>25</age></row>++
	</results>

	Query XML input:

		$ cat data.xml | sql-pipe -I xml 'SELECT name FROM t WHERE age > 25'

	Query XML input with nested structure using --xml-root and --xml-row (e.g. RSS feeds):

		$ curl -s https://feeds.example.com/news.rss \
		    | sql-pipe -I xml --xml-root channel --xml-row item 'SELECT title FROM t LIMIT 5'

	Output results as XML with custom element names:

		$ cat data.csv \
		    | sql-pipe -O xml --xml-root feed --xml-row entry 'SELECT * FROM t'

	Output results as a Markdown table:

		$ printf 'name,age\nAlice,30\nBob,25\nCarol,35' \
		    | sql-pipe -O markdown 'SELECT * FROM t'

	Output:++
	| name  | age |++
	|-------|-----|++
	| Alice |  30 |++
	| Bob   |  25 |++
	| Carol |  35 |

	Custom NULL representation (replace NULL with empty string):

		$ printf 'name,email\nAlice,a@b.com\nBob,\nCarol,c@d.com' \
		    | sql-pipe --null-value '' 'SELECT * FROM t'

	Output:++
	Alice,a@b.com++
	Bob,++
	Carol,c@d.com

	Preview schema and first 3 rows of a CSV file:

		$ cat sales.csv | sql-pipe --sample 3

	Output on stderr:++
	# Schema (3 columns):++
	#   id       INTEGER++
	#   region   TEXT++
	#   amount   REAL++
	Output on stdout:++
	id,region,amount++
	1,North,1250.00++
	2,South,875.50++
	3,East,2100.75

	Inspect query execution plan before running (plan goes to stderr,
	results to stdout):

		$ printf 'region,amount\nEast,100\nWest,200\n' | sql-pipe --explain 'SELECT region, SUM(amount) FROM t GROUP BY region'
		QUERY PLAN: SCAN t
		East,100
		West,200

	Print inferred CREATE TABLE DDL without running a query:

		$ printf 'name,age\nAlice,30\nBob,25\n' | sql-pipe --schema
		CREATE TABLE "t" ("name" TEXT, "age" INTEGER);

EXIT CODES
	*0*
		Success: query executed successfully and results were output.

	*1*
		Usage error: missing query argument, unrecognized flag, or argument parsing
		failure.

	*2*
		CSV parse error: malformed CSV input (e.g., mismatched quotes, incomplete
		fields).

	*3*
		SQL error: query execution failed in SQLite (e.g., invalid SQL syntax,
		type mismatch, or missing table).

AUTHORS
	Victor Varela <https://github.com/vmvarela>

SEE ALSO
	*sqlite3*(1), *csv*(5)

	For more information, visit https://github.com/vmvarela/sql-pipe
