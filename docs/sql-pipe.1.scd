sql-pipe(1)

NAME
	sql-pipe - Execute SQL queries on CSV data from stdin

SYNOPSIS
	*sql-pipe* [OPTIONS] <query>

DESCRIPTION
	sql-pipe reads CSV data from standard input, loads it into an in-memory SQLite
	database table named *t*, executes the provided SQL query, and prints the results
	as CSV to standard output.

	This tool is useful for quick data transformations, filtering, grouping, and
	aggregations on CSV files without manual SQL database setup.

	All input columns are automatically loaded into the table with names derived from
	the CSV header row. By default, column types (TEXT, INTEGER, REAL) are inferred
	from the first 100 rows of data. Use *--no-type-inference* to disable this
	behavior and treat all columns as TEXT.

	Exit codes follow a structured convention for scripting integration (see EXIT CODES
	section).

OPTIONS
	*--no-type-inference*
		Treat all columns as TEXT. Skips automatic type detection and uses plain
		TEXT affinity for all columns in the SQLite table. This can improve
		performance on very large datasets if type inference is not needed.

	*-h, --help*
		Print the help message and exit with code 0.

	*-V, --version*
		Print the version number and exit with code 0.

EXAMPLES
	Select all rows. Use a comma-separated list of columns or asterisk for all:

		$ cat <<'EOF' | sql-pipe 'SELECT name, age FROM t'
		name,age
		Alice,30
		Bob,25
		EOF
		name,age
		Alice,30
		Bob,25

	Group data by region and sum revenue:

		$ cat sales.csv | sql-pipe 'SELECT region, SUM(revenue) FROM t GROUP BY region'

	Filter rows where age is greater than 25:

		$ sql-pipe 'SELECT name FROM t WHERE age > 25' < data.csv

	Process data with type inference disabled:

		$ cat numbers.csv | sql-pipe --no-type-inference 'SELECT name, id FROM t WHERE id = "001"'

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
