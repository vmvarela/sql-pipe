sql-pipe(1)

NAME
	sql-pipe - Execute SQL queries on CSV data from stdin

SYNOPSIS
	*sql-pipe* [OPTIONS] <query>
	*sql-pipe* --columns [OPTIONS]
	*sql-pipe* --sample [<n>] [OPTIONS]

DESCRIPTION
	sql-pipe reads CSV data from standard input, loads it into an in-memory SQLite
	database table named *t*, executes the provided SQL query, and prints the results
	as CSV (or JSON when *--json* is used) to standard output.

	This tool is useful for quick data transformations, filtering, grouping, and
	aggregations on CSV files without manual SQL database setup.

	All input columns are automatically loaded into the table with names derived from
	the CSV header row. By default, column types (TEXT, INTEGER, REAL) are inferred
	from the first 100 rows of data. Use *--no-type-inference* to disable this
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
		also shows the inferred type (INTEGER, REAL, or TEXT) for each column
		(CSV/TSV only; other formats always show TEXT), using the first 100
		data rows for inference. Respects *--delimiter* and *--tsv*.
		Mutually exclusive with a query argument.

	*--sample* [<n>]
		Print a schema comment block to standard error and the first <n> data
		rows to standard output as delimited text (default: 10 rows if no value
		is given). The schema block lists each column name and its inferred
		SQLite type (INTEGER, REAL, or TEXT), each line prefixed with *#* so it
		is ignored by downstream CSV parsers. Column header is always printed as
		the first output row (implies *--header*). Type inference reads up to
		100 rows or <n> rows, whichever is larger, before emitting output.
		Compatible with *--delimiter* and *--tsv*. Mutually exclusive with
		*--json*, *--columns*, *--validate*, and a query argument. CSV and TSV
		input only.

	*--output* <file>
		Write results to <file> instead of standard output. Creates or
		overwrites the file. Compatible with all output modes (*--json*,
		*--header*, CSV). Exits with code 1 and an error message if the file
		cannot be created (bad path or insufficient permissions).

	*-h, --help*
		Print the help message and exit with code 0.

	*-V, --version*
		Print the version number and exit with code 0.

EXAMPLES
	Select all rows:

		$ cat people.csv | sql-pipe 'SELECT name, age FROM t'

	Output:++
	Alice,30++
	Bob,25

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
