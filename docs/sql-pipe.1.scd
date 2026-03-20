sql-pipe(1)

NAME
	sql-pipe - Execute SQL queries on CSV data from stdin

SYNOPSIS
	*sql-pipe* [OPTIONS] <query>

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
	*--delimiter* (or *-d*) to parse other single-character delimiters, or *--tsv*
	for tab-separated input.

	Exit codes follow a structured convention for scripting integration (see EXIT CODES
	section).

OPTIONS
	*-d, --delimiter* <char>
		Use a custom single-character input field delimiter instead of comma.
		Examples: *-d '|'* for pipe-separated files, *--delimiter '\\t'* for
		tab-separated files.

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
