const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Use -Dbundle-sqlite=true to compile sqlite3.c from lib/ instead of
    // linking the system library. Required for cross-compilation.
    const bundle_sqlite = b.option(
        bool,
        "bundle-sqlite",
        "Compile SQLite from lib/sqlite3.c (enables cross-compilation)",
    ) orelse false;

    // Version: release CI injects from git tag with -Dversion=X.Y.Z
    const version = b.option(
        []const u8,
        "version",
        "Override version string (default: from build.zig.zon)",
    ) orelse "0.0.0-dev";

    const exe = b.addExecutable(.{
        .name = "sql-pipe",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });

    // Inject version string as a compile-time option accessible via @import("build_options")
    const build_options = b.addOptions();
    build_options.addOption([]const u8, "version", version);
    exe.root_module.addOptions("build_options", build_options);

    // Translate sqlite3.h to Zig declarations, exposed as @import("c").
    // We always use lib/sqlite3.h for stable type declarations regardless of
    // whether we bundle or link the system SQLite library.
    const translate_c = b.addTranslateC(.{
        .root_source_file = b.path("lib/sqlite3.h"),
        .target = target,
        .optimize = optimize,
    });
    exe.root_module.addImport("c", translate_c.createModule());

    if (bundle_sqlite) {
        exe.root_module.addIncludePath(b.path("lib"));
        exe.root_module.addCSourceFile(.{
            .file = b.path("lib/sqlite3.c"),
            .flags = &.{"-DSQLITE_OMIT_LOAD_EXTENSION=1"},
        });
    } else {
        exe.root_module.linkSystemLibrary("sqlite3", .{});
    }

    b.installArtifact(exe);

    // Generate man page from scdoc source if scdoc (and gzip) are available (optional dependencies)
    const man_step = b.step("man", "Generate man page with scdoc (optional)");

    // Portable alternative: use a simple shell command that checks for scdoc/gzip availability
    // The build step itself is lightweight and depends only on bash (standard on CI/Unix systems)
    const build_man = b.addSystemCommand(&.{
        "bash", "-c",
        \\if command -v scdoc >/dev/null 2>&1 && command -v gzip >/dev/null 2>&1; then
        \\  mkdir -p zig-out/share/man/man1
        \\  scdoc < docs/sql-pipe.1.scd | gzip -c > zig-out/share/man/man1/sql-pipe.1.gz
        \\  echo "✓ Generated man page: zig-out/share/man/man1/sql-pipe.1.gz"
        \\else
        \\  echo "⚠ scdoc and/or gzip not found. Install them to generate man page."
        \\  echo "  Manual source: docs/sql-pipe.1.scd"
        \\fi
    });
    man_step.dependOn(&build_man.step);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    // Integration test 1: type inference — numeric comparisons work without CAST
    const test_infer = b.addSystemCommand(&.{
        "bash", "-c",
        \\printf 'name,age\nAlice,30\nBob,25\nCarol,35' | ./zig-out/bin/sql-pipe 'SELECT name FROM t WHERE age > 27' | diff - <(printf 'Alice\nCarol\n')
    });
    test_infer.step.dependOn(b.getInstallStep());

    // Integration test 2: --no-type-inference preserves legacy TEXT behavior
    // With TEXT comparison: "9" > "2" is true, but "10" > "2" is false (string: "1" < "2")
    // So only Alice is returned, proving string comparison is used
    const test_no_infer = b.addSystemCommand(&.{
        "bash", "-c",
        \\printf 'name,val\nAlice,9\nBob,10\n' | ./zig-out/bin/sql-pipe --no-type-inference 'SELECT name FROM t WHERE val > 2 ORDER BY name' | diff - <(printf 'Alice\n')
    });
    test_no_infer.step.dependOn(b.getInstallStep());

    // Integration test 3: max/min on REAL columns return numeric results
    const test_real = b.addSystemCommand(&.{
        "bash", "-c",
        \\printf 'item,price\nA,9.99\nB,3.00\nC,12.50\n' | ./zig-out/bin/sql-pipe 'SELECT max(price), min(price) FROM t' | diff - <(printf '12.5,3.0\n')
    });
    test_real.step.dependOn(b.getInstallStep());

    const test_step = b.step("test", "Run integration tests");
    test_step.dependOn(&test_infer.step);
    test_step.dependOn(&test_no_infer.step);
    test_step.dependOn(&test_real.step);

    // Integration test 4: --help flag prints usage to stderr and exits 0
    const test_help = b.addSystemCommand(&.{
        "bash", "-c",
        \\./zig-out/bin/sql-pipe --help 2>&1 >/dev/null | grep -q 'Usage: sql-pipe'
    });
    test_help.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_help.step);

    // Integration test 5: --version flag prints version to stderr and exits 0
    const test_version = b.addSystemCommand(&.{
        "bash", "-c",
        \\./zig-out/bin/sql-pipe --version 2>&1 >/dev/null | grep -q 'sql-pipe'
    });
    test_version.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_version.step);

    // Integration test 6: missing query exits with code 1
    const test_missing_query = b.addSystemCommand(&.{
        "bash", "-c",
        \\./zig-out/bin/sql-pipe 2>/dev/null; test $? -eq 1
    });
    test_missing_query.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_missing_query.step);

    // Integration test 7: SQL error exits with code 3 and prefixes with "error:"
    const test_sql_error = b.addSystemCommand(&.{
        "bash", "-c",
        \\msg=$(printf 'a\n1\n' | ./zig-out/bin/sql-pipe 'SELECT * FROM nonexistent' 2>&1 >/dev/null; echo "EXIT:$?"); echo "$msg" | grep -q '^error:' && echo "$msg" | grep -q 'EXIT:3'
    });
    test_sql_error.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_sql_error.step);

    // Integration test 8: --delimiter "|" reads pipe-separated input; output is always CSV
    const test_delimiter_pipe = b.addSystemCommand(&.{
        "bash", "-c",
        \\printf 'name|age\nAlice|30\nBob|25\n' | ./zig-out/bin/sql-pipe --delimiter '|' 'SELECT name, age FROM t ORDER BY age' | diff - <(printf 'Bob,25\nAlice,30\n')
    });
    test_delimiter_pipe.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_delimiter_pipe.step);

    // Integration test 9: --delimiter "\t" reads tab-separated input
    const test_delimiter_tab = b.addSystemCommand(&.{
        "bash", "-c",
        \\printf 'name\tage\nAlice\t30\nBob\t25\n' | ./zig-out/bin/sql-pipe --delimiter '\t' 'SELECT name, age FROM t ORDER BY age' | diff - <(printf 'Bob,25\nAlice,30\n')
    });
    test_delimiter_tab.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_delimiter_tab.step);

    // Integration test 10: --tsv is an alias for --delimiter "\t"
    const test_tsv = b.addSystemCommand(&.{
        "bash", "-c",
        \\printf 'name\tage\nAlice\t30\nBob\t25\n' | ./zig-out/bin/sql-pipe --tsv 'SELECT name, age FROM t ORDER BY age' | diff - <(printf 'Bob,25\nAlice,30\n')
    });
    test_tsv.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_tsv.step);

    // Integration test 11: --header includes column names as the first output row
    const test_header = b.addSystemCommand(&.{
        "bash", "-c",
        \\printf 'name,age\nAlice,30\nBob,25\n' | ./zig-out/bin/sql-pipe --header 'SELECT name, age FROM t ORDER BY age' | diff - <(printf 'name,age\nBob,25\nAlice,30\n')
    });
    test_header.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_header.step);

    // Integration test 12: --header combined with --delimiter (pipe-separated input, CSV output with header)
    const test_header_delimiter = b.addSystemCommand(&.{
        "bash", "-c",
        \\printf 'name|age\nAlice|30\nBob|25\n' | ./zig-out/bin/sql-pipe --header --delimiter '|' 'SELECT name, age FROM t ORDER BY age' | diff - <(printf 'name,age\nBob,25\nAlice,30\n')
    });
    test_header_delimiter.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_header_delimiter.step);

    // Integration test 13: default behavior (no flags) produces CSV without header
    const test_default_no_header = b.addSystemCommand(&.{
        "bash", "-c",
        \\printf 'name,age\nAlice,30\nBob,25\n' | ./zig-out/bin/sql-pipe 'SELECT name, age FROM t ORDER BY name' | diff - <(printf 'Alice,30\nBob,25\n')
    });
    test_default_no_header.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_default_no_header.step);

    // Integration test 14: --json emits a JSON array of objects
    const test_json = b.addSystemCommand(&.{
        "bash", "-c",
        \\printf 'name,age\nAlice,30\nBob,25\n' | ./zig-out/bin/sql-pipe --json 'SELECT name, age FROM t ORDER BY age' | diff - <(printf '[{"name":"Bob","age":25},{"name":"Alice","age":30}]\n')
    });
    test_json.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_json.step);

    // Integration test 15: --json NULL values are rendered as JSON null
    const test_json_null = b.addSystemCommand(&.{
        "bash", "-c",
        \\exp='[{"name":"Alice","score":null},{"name":"Bob","score":9.5}]'
        \\printf 'name,score\nAlice,\nBob,9.5\n' | ./zig-out/bin/sql-pipe --json 'SELECT name, score FROM t ORDER BY name' | diff - <(printf '%s\n' "$exp")
    });
    test_json_null.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_json_null.step);

    // Integration test 16: --json empty result set produces []
    const test_json_empty = b.addSystemCommand(&.{
        "bash", "-c",
        \\printf 'name,age\n' | ./zig-out/bin/sql-pipe --json 'SELECT * FROM t' | diff - <(printf '[]\n')
    });
    test_json_empty.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_json_empty.step);

    // Integration test 17: --json is mutually exclusive with --header (exits 1)
    const test_json_incompatible = b.addSystemCommand(&.{
        "bash", "-c",
        \\printf 'name,age\nAlice,30\n' | ./zig-out/bin/sql-pipe --json --header 'SELECT * FROM t'; test $? -eq 1
    });
    test_json_incompatible.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_json_incompatible.step);

    // Integration test 17b: --json is compatible with --delimiter (delimiter affects input only)
    const test_json_with_delimiter = b.addSystemCommand(&.{
        "bash", "-c",
        \\printf 'name;age\nAlice;30\nBob;25\n' | ./zig-out/bin/sql-pipe --json -d ';' 'SELECT name, age FROM t ORDER BY age' | diff - <(printf '[{"name":"Bob","age":25},{"name":"Alice","age":30}]\n')
    });
    test_json_with_delimiter.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_json_with_delimiter.step);

    // Integration test 18: duplicate column names emit warning to stderr
    const test_dup_col_warning = b.addSystemCommand(&.{
        "bash", "-c",
        \\printf 'id,value,value\n1,a,b\n' | ./zig-out/bin/sql-pipe 'SELECT value_2 FROM t' 2>&1 >/dev/null | grep -q 'warning: duplicate column "value" renamed to "value_2"'
    });
    test_dup_col_warning.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_dup_col_warning.step);

    // Integration test 19: duplicate column warning does not corrupt stdout
    const test_dup_col_stdout = b.addSystemCommand(&.{
        "bash", "-c",
        \\printf 'id,value,value\n1,a,b\n' | ./zig-out/bin/sql-pipe 'SELECT value_2 FROM t' 2>/dev/null | diff - <(printf 'b\n')
    });
    test_dup_col_stdout.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_dup_col_stdout.step);

    // Integration test 20: --max-rows under limit succeeds
    const test_max_rows_under = b.addSystemCommand(&.{
        "bash", "-c",
        \\printf 'name,age\nAlice,30\nBob,25\n' | ./zig-out/bin/sql-pipe --max-rows 5 'SELECT name FROM t ORDER BY name' | diff - <(printf 'Alice\nBob\n')
    });
    test_max_rows_under.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_max_rows_under.step);

    // Integration test 21: --max-rows limit hit exits 1 with error message
    const test_max_rows_hit = b.addSystemCommand(&.{
        "bash", "-c",
        \\msg=$(printf 'name,age\nAlice,30\nBob,25\nCarol,35\n' | ./zig-out/bin/sql-pipe --max-rows 1 'SELECT * FROM t' 2>&1 >/dev/null; echo "EXIT:$?")
        \\echo "$msg" | grep -q 'error: input exceeds --max-rows limit (1 rows)' && echo "$msg" | grep -q 'EXIT:1'
    });
    test_max_rows_hit.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_max_rows_hit.step);

    // Integration test 22: --max-rows 0 exits 1 with error message
    const test_max_rows_zero = b.addSystemCommand(&.{
        "bash", "-c",
        \\msg=$(printf 'name,age\nAlice,30\n' | ./zig-out/bin/sql-pipe --max-rows 0 'SELECT * FROM t' 2>&1 >/dev/null; echo "EXIT:$?")
        \\echo "$msg" | grep -q 'error: --max-rows must be a positive integer' && echo "$msg" | grep -q 'EXIT:1'
    });
    test_max_rows_zero.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_max_rows_zero.step);

    // Integration test 23: --max-rows=5 (equals form) succeeds
    const test_max_rows_equals = b.addSystemCommand(&.{
        "bash", "-c",
        \\printf 'name,age\nAlice,30\nBob,25\n' | ./zig-out/bin/sql-pipe --max-rows=5 'SELECT name FROM t ORDER BY name' | diff - <(printf 'Alice\nBob\n')
    });
    test_max_rows_equals.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_max_rows_equals.step);

    // Integration test 24: --max-rows with non-numeric value exits 1
    const test_max_rows_nan = b.addSystemCommand(&.{
        "bash", "-c",
        \\printf 'name,age\nAlice,30\n' | ./zig-out/bin/sql-pipe --max-rows abc 'SELECT * FROM t' 2>&1 >/dev/null; test $? -eq 1
    });
    test_max_rows_nan.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_max_rows_nan.step);

    // Integration test 25: --no-type-inference --max-rows 1 hits limit and exits 1
    const test_max_rows_streaming = b.addSystemCommand(&.{
        "bash", "-c",
        \\msg=$(printf 'name,age\nAlice,30\nBob,25\n' | ./zig-out/bin/sql-pipe --no-type-inference --max-rows 1 'SELECT * FROM t' 2>&1 >/dev/null; echo "EXIT:$?") && echo "$msg" | grep -q 'EXIT:1'
    });
    test_max_rows_streaming.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_max_rows_streaming.step);

    // Integration test 26: SQL error on unknown column prints column list to stderr
    const test_sql_error_col_list = b.addSystemCommand(&.{
        "bash", "-c",
        \\msg=$(printf 'id,amount,region\n1,100,east\n' | ./zig-out/bin/sql-pipe 'SELECT revenue FROM t' 2>&1 >/dev/null; echo "EXIT:$?")
        \\echo "$msg" | grep -q 'no such column: revenue' \
        \\  && echo "$msg" | grep -q 'table "t" has columns: id, amount, region' \
        \\  && echo "$msg" | grep -q 'EXIT:3'
    });
    test_sql_error_col_list.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_sql_error_col_list.step);

    // Integration test 27: SQL error on near-miss column name prints "did you mean" hint
    const test_sql_error_hint = b.addSystemCommand(&.{
        "bash", "-c",
        \\msg=$(printf 'id,amount,region\n1,100,east\n' | ./zig-out/bin/sql-pipe 'SELECT amout FROM t' 2>&1 >/dev/null; echo "EXIT:$?")
        \\echo "$msg" | grep -q 'hint: did you mean "amount"' && echo "$msg" | grep -q 'EXIT:3'
    });
    test_sql_error_hint.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_sql_error_hint.step);

    // Integration test 28: CSV parse error includes 1-based row number in message
    const test_csv_row_number = b.addSystemCommand(&.{
        "bash", "-c",
        \\msg=$(printf 'name,age\n"unterminated' | ./zig-out/bin/sql-pipe 'SELECT * FROM t' 2>&1 >/dev/null; echo "EXIT:$?")
        \\echo "$msg" | grep -q 'row 2: unterminated quoted field' && echo "$msg" | grep -q 'EXIT:2'
    });
    test_csv_row_number.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_csv_row_number.step);

    // Integration test 29: --verbose prints "Loaded <n> rows" to stderr
    const test_verbose_count = b.addSystemCommand(&.{
        "bash", "-c",
        \\printf 'name,age\nAlice,30\nBob,25\nCarol,35\n' | ./zig-out/bin/sql-pipe --verbose 'SELECT COUNT(*) FROM t' 2>&1 >/dev/null | grep -q 'Loaded 3 rows'
    });
    test_verbose_count.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_verbose_count.step);

    // Integration test 30: --verbose formats thousands separator (e.g. 1,000 not 1000)
    const test_verbose_thousands = b.addSystemCommand(&.{
        "bash", "-c",
        \\{ printf 'n\n'; seq 1 1000; } | ./zig-out/bin/sql-pipe --verbose 'SELECT COUNT(*) FROM t' 2>&1 >/dev/null | grep -q 'Loaded 1,000 rows'
    });
    test_verbose_thousands.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_verbose_thousands.step);

    // Integration test 31: without --verbose, row count is NOT printed to stderr (non-TTY)
    // Note: `2>&1 >/dev/null` redirects stderr to the subshell's stdout (captured in $out),
    //       then redirects stdout to /dev/null. The TTY check suppresses the count in this
    //       non-interactive context, so $out should be empty.
    const test_no_verbose_silent = b.addSystemCommand(&.{
        "bash", "-c",
        \\out=$(printf 'name,age\nAlice,30\n' | ./zig-out/bin/sql-pipe 'SELECT * FROM t' 2>&1 >/dev/null)
        \\test -z "$out"
    });
    test_no_verbose_silent.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_no_verbose_silent.step);

    // Integration test 32: -v is an alias for --verbose
    const test_verbose_short = b.addSystemCommand(&.{
        "bash", "-c",
        \\printf 'name,age\nAlice,30\n' | ./zig-out/bin/sql-pipe -v 'SELECT * FROM t' 2>&1 >/dev/null | grep -q 'Loaded 1 rows'
    });
    test_verbose_short.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_verbose_short.step);

    // Integration test 33: --columns prints column names one per line and exits 0
    const test_columns_basic = b.addSystemCommand(&.{
        "bash", "-c",
        \\printf 'id,region,amount\n1,east,100\n' | ./zig-out/bin/sql-pipe --columns | diff - <(printf 'id\nregion\namount\n')
    });
    test_columns_basic.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_columns_basic.step);

    // Integration test 34: --columns --verbose prints "name TYPE" lines
    const test_columns_verbose = b.addSystemCommand(&.{
        "bash", "-c",
        \\printf 'id,name,amount\n1,Alice,3.14\n2,Bob,2.72\n' | ./zig-out/bin/sql-pipe --columns --verbose | diff - <(printf 'id INTEGER\nname TEXT\namount REAL\n')
    });
    test_columns_verbose.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_columns_verbose.step);

    // Integration test 35: --columns works with --delimiter
    const test_columns_delimiter = b.addSystemCommand(&.{
        "bash", "-c",
        \\printf 'a|b|c\n1|2|3\n' | ./zig-out/bin/sql-pipe --columns -d '|' | diff - <(printf 'a\nb\nc\n')
    });
    test_columns_delimiter.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_columns_delimiter.step);

    // Integration test 36: --columns works with --tsv
    const test_columns_tsv = b.addSystemCommand(&.{
        "bash", "-c",
        \\printf 'col1\tcol2\tcol3\n' | ./zig-out/bin/sql-pipe --columns --tsv | diff - <(printf 'col1\ncol2\ncol3\n')
    });
    test_columns_tsv.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_columns_tsv.step);

    // Integration test 37: --columns with a non-file positional arg exits 2 with error
    const test_columns_with_query = b.addSystemCommand(&.{
        "bash", "-c",
        \\msg=$(printf 'a,b\n1,2\n' | ./zig-out/bin/sql-pipe --columns 'SELECT * FROM t' 2>&1 >/dev/null; echo "EXIT:$?")
        \\echo "$msg" | grep -q 'error: cannot open file' && echo "$msg" | grep -q 'EXIT:2'
    });
    test_columns_with_query.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_columns_with_query.step);

    // Integration test 38: --columns --verbose with malformed CSV exits 2
    const test_columns_verbose_bad_csv = b.addSystemCommand(&.{
        "bash", "-c",
        \\msg=$(printf 'a,b\n"unterminated' | ./zig-out/bin/sql-pipe --columns --verbose 2>&1 >/dev/null; echo "EXIT:$?")
        \\echo "$msg" | grep -q 'row 2: unterminated quoted field' && echo "$msg" | grep -q 'EXIT:2'
    });
    test_columns_verbose_bad_csv.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_columns_verbose_bad_csv.step);

    // Integration test 39: --columns --verbose with header-only (no data rows) → all TEXT
    const test_columns_verbose_no_data = b.addSystemCommand(&.{
        "bash", "-c",
        \\printf 'id,name\n' | ./zig-out/bin/sql-pipe --columns --verbose | diff - <(printf 'id TEXT\nname TEXT\n')
    });
    test_columns_verbose_no_data.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_columns_verbose_no_data.step);

    // Integration test 40: --columns with empty stdin exits 2
    const test_columns_empty_stdin = b.addSystemCommand(&.{
        "bash", "-c",
        \\printf '' | ./zig-out/bin/sql-pipe --columns 2>/dev/null; test $? -eq 2
    });
    test_columns_empty_stdin.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_columns_empty_stdin.step);

    // Integration test 41: -v is a valid alias for --verbose with --columns
    const test_columns_short_verbose = b.addSystemCommand(&.{
        "bash", "-c",
        \\printf 'id,name\n1,Alice\n' | ./zig-out/bin/sql-pipe --columns -v | diff - <(printf 'id INTEGER\nname TEXT\n')
    });
    test_columns_short_verbose.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_columns_short_verbose.step);

    // Integration test 42: --output writes results to a file
    const test_output_file = b.addSystemCommand(&.{
        "bash", "-c",
        \\tmp=$(mktemp); printf 'name,age\nAlice,30\nBob,25\n' | ./zig-out/bin/sql-pipe --output "$tmp" 'SELECT name FROM t ORDER BY age'; diff "$tmp" <(printf 'Bob\nAlice\n'); rm -f "$tmp"
    });
    test_output_file.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_output_file.step);

    // Integration test 43: --output works with --json
    const test_output_json = b.addSystemCommand(&.{
        "bash", "-c",
        \\tmp=$(mktemp); printf 'name,age\nAlice,30\n' | ./zig-out/bin/sql-pipe --json --output "$tmp" 'SELECT * FROM t'; grep -q '"name":"Alice"' "$tmp"; rm -f "$tmp"
    });
    test_output_json.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_output_json.step);

    // Integration test 44: --output with missing parent directory exits 1 with error message
    const test_output_bad_path = b.addSystemCommand(&.{
        "bash", "-c",
        \\msg=$(printf 'a\n1\n' | ./zig-out/bin/sql-pipe --output '/nonexistent/dir/file.csv' 'SELECT * FROM t' 2>&1 >/dev/null; echo "EXIT:$?")
        \\echo "$msg" | grep -q "^error:" && echo "$msg" | grep -q 'EXIT:1'
    });
    test_output_bad_path.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_output_bad_path.step);

    // Integration test 45: --output works with --header
    const test_output_header = b.addSystemCommand(&.{
        "bash", "-c",
        \\tmp=$(mktemp); printf 'name,age\nAlice,30\n' | ./zig-out/bin/sql-pipe --header --output "$tmp" 'SELECT name FROM t'; diff "$tmp" <(printf 'name\nAlice\n'); rm -f "$tmp"
    });
    test_output_header.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_output_header.step);

    // Integration test 46: --output cannot be combined with --columns (exits 1 with error)
    const test_output_with_columns = b.addSystemCommand(&.{
        "bash", "-c",
        \\msg=$(printf 'a,b\n1,2\n' | ./zig-out/bin/sql-pipe --columns --output /tmp/out.csv 2>&1 >/dev/null; echo "EXIT:$?")
        \\echo "$msg" | grep -q 'error: --output cannot be combined with --columns' && echo "$msg" | grep -q 'EXIT:1'
    });
    test_output_with_columns.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_output_with_columns.step);

    // Integration test 47: --output on SQL error flushes partial output before exit
    const test_output_sql_error_flush = b.addSystemCommand(&.{
        "bash", "-c",
        \\tmp=$(mktemp)
        \\printf 'name,age\nAlice,30\nBob,25\n' | ./zig-out/bin/sql-pipe --header --output "$tmp" 'SELECT * FROM nonexistent_table' 2>/dev/null; test $? -eq 3
        \\rm -f "$tmp"
    });
    test_output_sql_error_flush.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_output_sql_error_flush.step);
    test_output_bad_path.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_output_bad_path.step);

    // ─── JSON / NDJSON input/output integration tests ────────────────────────

    // Integration test 48: JSON array input → CSV output
    const test_json_input_csv_out = b.addSystemCommand(&.{
        "bash", "-c",
        \\result=$(printf '[{"name":"Alice","age":30},{"name":"Bob","age":25}]' \
        \\    | ./zig-out/bin/sql-pipe --input-format json 'SELECT name,age FROM t ORDER BY age')
        \\expected=$(printf 'Bob,25\nAlice,30')
        \\[ "$result" = "$expected" ]
    });
    test_json_input_csv_out.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_json_input_csv_out.step);

    // Integration test 49: CSV input → JSON output (--json alias)
    const test_csv_to_json = b.addSystemCommand(&.{
        "bash", "-c",
        \\result=$(printf 'name,age\nAlice,30\nBob,25\n' \
        \\    | ./zig-out/bin/sql-pipe --json 'SELECT name,age FROM t ORDER BY age')
        \\expected=$(printf '[{"name":"Bob","age":25},{"name":"Alice","age":30}]\n')
        \\[ "$result" = "$expected" ]
    });
    test_csv_to_json.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_csv_to_json.step);

    // Integration test 50: CSV input → JSON output (--output-format json)
    const test_output_format_json = b.addSystemCommand(&.{
        "bash", "-c",
        \\result=$(printf 'name,age\nAlice,30\n' \
        \\    | ./zig-out/bin/sql-pipe --output-format json 'SELECT * FROM t')
        \\expected=$(printf '[{"name":"Alice","age":30}]\n')
        \\[ "$result" = "$expected" ]
    });
    test_output_format_json.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_output_format_json.step);

    // Integration test 51: CSV input → NDJSON output
    const test_csv_to_ndjson = b.addSystemCommand(&.{
        "bash", "-c",
        \\result=$(printf 'name,age\nAlice,30\nBob,25\n' \
        \\    | ./zig-out/bin/sql-pipe --output-format ndjson 'SELECT name,age FROM t ORDER BY age')
        \\expected=$(printf '{"name":"Bob","age":25}\n{"name":"Alice","age":30}\n')
        \\[ "$result" = "$expected" ]
    });
    test_csv_to_ndjson.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_csv_to_ndjson.step);

    // Integration test 52: NDJSON input → CSV output
    const test_ndjson_input_csv_out = b.addSystemCommand(&.{
        "bash", "-c",
        \\result=$(printf '{"name":"Alice","age":30}\n{"name":"Bob","age":25}\n' \
        \\    | ./zig-out/bin/sql-pipe --input-format ndjson 'SELECT name,age FROM t ORDER BY age')
        \\expected=$(printf 'Bob,25\nAlice,30')
        \\[ "$result" = "$expected" ]
    });
    test_ndjson_input_csv_out.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_ndjson_input_csv_out.step);

    // Integration test 53: NDJSON input → NDJSON output (-I / -O short flags)
    const test_ndjson_roundtrip = b.addSystemCommand(&.{
        "bash", "-c",
        \\result=$(printf '{"name":"Alice","age":30}\n{"name":"Bob","age":25}\n' \
        \\    | ./zig-out/bin/sql-pipe -I ndjson -O ndjson 'SELECT name FROM t WHERE age > 26')
        \\expected=$(printf '{"name":"Alice"}\n')
        \\[ "$result" = "$expected" ]
    });
    test_ndjson_roundtrip.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_ndjson_roundtrip.step);

    // Integration test 54: JSON input with null value
    const test_json_null_value = b.addSystemCommand(&.{
        "bash", "-c",
        \\result=$(printf '[{"name":"Alice","age":null}]' \
        \\    | ./zig-out/bin/sql-pipe -I json -O json 'SELECT name, age FROM t')
        \\expected=$(printf '[{"name":"Alice","age":null}]\n')
        \\[ "$result" = "$expected" ]
    });
    test_json_null_value.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_json_null_value.step);

    // Integration test 55: JSON input with boolean value (stored as 1/0)
    const test_json_bool_value = b.addSystemCommand(&.{
        "bash", "-c",
        \\result=$(printf '[{"active":true},{"active":false}]' \
        \\    | ./zig-out/bin/sql-pipe -I json 'SELECT active FROM t ORDER BY active')
        \\expected=$(printf '0\n1')
        \\[ "$result" = "$expected" ]
    });
    test_json_bool_value.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_json_bool_value.step);

    // Integration test 56: empty JSON array → no such table error (table not created)
    const test_json_empty_array = b.addSystemCommand(&.{
        "bash", "-c",
        \\msg=$(printf '[]' | ./zig-out/bin/sql-pipe -I json 'SELECT * FROM t' 2>&1 >/dev/null; echo "EXIT:$?")
        \\echo "$msg" | grep -q 'no such table' && echo "$msg" | grep -q 'EXIT:3'
    });
    test_json_empty_array.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_json_empty_array.step);

    // Integration test 57: unknown input format → error exit 1
    const test_bad_input_format = b.addSystemCommand(&.{
        "bash", "-c",
        \\msg=$(printf '' | ./zig-out/bin/sql-pipe --input-format parquet 'SELECT 1' 2>&1 >/dev/null; echo "EXIT:$?")
        \\echo "$msg" | grep -q 'unknown input format' && echo "$msg" | grep -q 'EXIT:1'
    });
    test_bad_input_format.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_bad_input_format.step);

    // Integration test 58: unknown output format → error exit 1
    const test_bad_output_format = b.addSystemCommand(&.{
        "bash", "-c",
        \\msg=$(printf 'a\n1\n' | ./zig-out/bin/sql-pipe --output-format parquet 'SELECT * FROM t' 2>&1 >/dev/null; echo "EXIT:$?")
        \\echo "$msg" | grep -q 'unknown output format' && echo "$msg" | grep -q 'EXIT:1'
    });
    test_bad_output_format.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_bad_output_format.step);

    // Integration test 59: --header with --output-format json → IncompatibleFlags error exit 1
    const test_header_with_json_format = b.addSystemCommand(&.{
        "bash", "-c",
        \\msg=$(printf 'a\n1\n' | ./zig-out/bin/sql-pipe --header --output-format json 'SELECT * FROM t' 2>&1; echo "EXIT:$?")
        \\echo "$msg" | grep -q 'error:' && echo "$msg" | grep -q 'EXIT:1'
    });
    test_header_with_json_format.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_header_with_json_format.step);

    // Integration test 60: --columns with JSON input
    const test_columns_json_input = b.addSystemCommand(&.{
        "bash", "-c",
        \\result=$(printf '[{"name":"Alice","age":30}]' \
        \\    | ./zig-out/bin/sql-pipe --input-format json --columns)
        \\expected=$(printf 'name\nage')
        \\[ "$result" = "$expected" ]
    });
    test_columns_json_input.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_columns_json_input.step);

    // Integration test 61: --columns with NDJSON input
    const test_columns_ndjson_input = b.addSystemCommand(&.{
        "bash", "-c",
        \\result=$(printf '{"name":"Alice","age":30}\n' \
        \\    | ./zig-out/bin/sql-pipe -I ndjson --columns)
        \\expected=$(printf 'name\nage')
        \\[ "$result" = "$expected" ]
    });
    test_columns_ndjson_input.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_columns_ndjson_input.step);

    // ─── TSV input/output integration tests ─────────────────────────────────

    // Integration test 62: --input-format tsv reads tab-separated input correctly
    const test_tsv_input_format = b.addSystemCommand(&.{
        "bash", "-c",
        \\result=$(printf 'name\tage\nAlice\t30\nBob\t25\n' \
        \\    | ./zig-out/bin/sql-pipe --input-format tsv 'SELECT name,age FROM t ORDER BY age')
        \\expected=$(printf 'Bob,25\nAlice,30')
        \\[ "$result" = "$expected" ]
    });
    test_tsv_input_format.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_tsv_input_format.step);

    // Integration test 63: -I tsv short flag is equivalent to --input-format tsv
    const test_tsv_input_short = b.addSystemCommand(&.{
        "bash", "-c",
        \\result=$(printf 'name\tage\nAlice\t30\nBob\t25\n' \
        \\    | ./zig-out/bin/sql-pipe -I tsv 'SELECT name FROM t ORDER BY name')
        \\expected=$(printf 'Alice\nBob')
        \\[ "$result" = "$expected" ]
    });
    test_tsv_input_short.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_tsv_input_short.step);

    // Integration test 64: --output-format tsv produces tab-separated output
    const test_tsv_output_format = b.addSystemCommand(&.{
        "bash", "-c",
        \\result=$(printf 'name,age\nAlice,30\nBob,25\n' \
        \\    | ./zig-out/bin/sql-pipe --output-format tsv 'SELECT name,age FROM t ORDER BY age')
        \\expected=$(printf 'Bob\t25\nAlice\t30')
        \\[ "$result" = "$expected" ]
    });
    test_tsv_output_format.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_tsv_output_format.step);

    // Integration test 65: -O tsv short flag is equivalent to --output-format tsv
    const test_tsv_output_short = b.addSystemCommand(&.{
        "bash", "-c",
        \\result=$(printf 'name,age\nAlice,30\n' \
        \\    | ./zig-out/bin/sql-pipe -O tsv 'SELECT name,age FROM t')
        \\expected=$(printf 'Alice\t30')
        \\[ "$result" = "$expected" ]
    });
    test_tsv_output_short.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_tsv_output_short.step);

    // Integration test 66: TSV roundtrip (-I tsv -O tsv)
    const test_tsv_roundtrip = b.addSystemCommand(&.{
        "bash", "-c",
        \\result=$(printf 'name\tage\nAlice\t30\nBob\t25\n' \
        \\    | ./zig-out/bin/sql-pipe -I tsv -O tsv 'SELECT name,age FROM t ORDER BY name')
        \\expected=$(printf 'Alice\t30\nBob\t25')
        \\[ "$result" = "$expected" ]
    });
    test_tsv_roundtrip.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_tsv_roundtrip.step);

    // Integration test 67: CSV input, TSV output (cross-format)
    const test_csv_to_tsv = b.addSystemCommand(&.{
        "bash", "-c",
        \\result=$(printf 'name,age\nAlice,30\nBob,25\n' \
        \\    | ./zig-out/bin/sql-pipe -O tsv 'SELECT name,age FROM t ORDER BY name')
        \\expected=$(printf 'Alice\t30\nBob\t25')
        \\[ "$result" = "$expected" ]
    });
    test_csv_to_tsv.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_csv_to_tsv.step);

    // Integration test 68: --header works with --output-format tsv
    const test_header_tsv_output = b.addSystemCommand(&.{
        "bash", "-c",
        \\result=$(printf 'name,age\nAlice,30\nBob,25\n' \
        \\    | ./zig-out/bin/sql-pipe --header -O tsv 'SELECT name,age FROM t ORDER BY age')
        \\expected=$(printf 'name\tage\nBob\t25\nAlice\t30')
        \\[ "$result" = "$expected" ]
    });
    test_header_tsv_output.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_header_tsv_output.step);

    // Integration test 69: --columns with --input-format tsv
    const test_columns_tsv_input_format = b.addSystemCommand(&.{
        "bash", "-c",
        \\result=$(printf 'col1\tcol2\tcol3\n' \
        \\    | ./zig-out/bin/sql-pipe --columns --input-format tsv)
        \\expected=$(printf 'col1\ncol2\ncol3')
        \\[ "$result" = "$expected" ]
    });
    test_columns_tsv_input_format.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_columns_tsv_input_format.step);

    // Integration test 70: TSV input with a quoted field containing a tab
    // The tab inside a quoted field is unescaped during TSV parsing;
    // the resulting value (hello<tab>world) is written verbatim in CSV output
    // because comma is the output delimiter, not tab.
    const test_tsv_quoted_tab = b.addSystemCommand(&.{
        "bash", "-c",
        \\result=$(printf 'name\tnotes\nAlice\t"hello\tworld"\n' \
        \\    | ./zig-out/bin/sql-pipe -I tsv 'SELECT name, notes FROM t')
        \\expected=$(printf 'Alice,hello\tworld')
        \\[ "$result" = "$expected" ]
    });
    test_tsv_quoted_tab.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_tsv_quoted_tab.step);

    // Integration test 71: --silent suppresses row count output to stderr
    const test_silent = b.addSystemCommand(&.{
        "bash", "-c",
        \\out=$(printf 'name,age\nAlice,30\n' | ./zig-out/bin/sql-pipe --silent 'SELECT name FROM t' 2>&1 >/dev/null)
        \\test -z "$out"
    });
    test_silent.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_silent.step);

    // Integration test 72: -s is an alias for --silent
    const test_silent_short = b.addSystemCommand(&.{
        "bash", "-c",
        \\result=$(printf 'name,age\nAlice,30\n' | ./zig-out/bin/sql-pipe -s 'SELECT name FROM t')
        \\expected=$(printf 'Alice\n')
        \\[ "$result" = "$expected" ]
    });
    test_silent_short.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_silent_short.step);

    // Integration test 73: --silent combined with --verbose exits 1 with error
    const test_silent_verbose_conflict = b.addSystemCommand(&.{
        "bash", "-c",
        \\msg=$(printf 'a\n1\n' | ./zig-out/bin/sql-pipe --silent --verbose 'SELECT * FROM t' 2>&1 >/dev/null; echo "EXIT:$?")
        \\echo "$msg" | grep -q 'error: --silent cannot be combined with --verbose' && echo "$msg" | grep -q 'EXIT:1'
    });
    test_silent_verbose_conflict.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_silent_verbose_conflict.step);

    // Integration test 74: --silent combined with -v exits 1 with error
    const test_silent_v_conflict = b.addSystemCommand(&.{
        "bash", "-c",
        \\msg=$(printf 'a\n1\n' | ./zig-out/bin/sql-pipe --silent -v 'SELECT * FROM t' 2>&1 >/dev/null; echo "EXIT:$?")
        \\echo "$msg" | grep -q 'error: --silent cannot be combined with --verbose' && echo "$msg" | grep -q 'EXIT:1'
    });
    test_silent_v_conflict.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_silent_v_conflict.step);

    // Integration test 75: --validate on valid CSV prints OK summary and exits 0
    const test_validate_ok = b.addSystemCommand(&.{
        "bash", "-c",
        \\result=$(printf 'id,name,amount\n1,Alice,3.14\n2,Bob,2.72\n' | ./zig-out/bin/sql-pipe --validate)
        \\expected='OK: 2 rows, 3 columns (id INTEGER, name TEXT, amount REAL)'
        \\[ "$result" = "$expected" ]
    });
    test_validate_ok.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_validate_ok.step);

    // Integration test 76: --validate on malformed CSV exits 2
    const test_validate_error = b.addSystemCommand(&.{
        "bash", "-c",
        \\msg=$(printf 'id,name\n"unterminated' | ./zig-out/bin/sql-pipe --validate 2>&1 >/dev/null; echo "EXIT:$?")
        \\echo "$msg" | grep -q 'row 2: unterminated quoted field' && echo "$msg" | grep -q 'EXIT:2'
    });
    test_validate_error.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_validate_error.step);

    // Integration test 77: --validate with custom delimiter
    const test_validate_delimiter = b.addSystemCommand(&.{
        "bash", "-c",
        \\result=$(printf 'id|name|amount\n1|Alice|3.14\n' | ./zig-out/bin/sql-pipe --validate --delimiter '|')
        \\expected='OK: 1 rows, 3 columns (id INTEGER, name TEXT, amount REAL)'
        \\[ "$result" = "$expected" ]
    });
    test_validate_delimiter.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_validate_delimiter.step);

    // Integration test 78: --validate with a non-file positional arg exits 2
    const test_validate_with_query = b.addSystemCommand(&.{
        "bash", "-c",
        \\msg=$(printf 'a,b\n1,2\n' | ./zig-out/bin/sql-pipe --validate 'SELECT * FROM t' 2>&1 >/dev/null; echo "EXIT:$?")
        \\echo "$msg" | grep -q 'error: cannot open file' && echo "$msg" | grep -q 'EXIT:2'
    });
    test_validate_with_query.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_validate_with_query.step);

    // Integration test 79: --validate on valid JSON array
    const test_validate_json = b.addSystemCommand(&.{
        "bash", "-c",
        \\result=$(printf '[{"id":1,"name":"Alice"},{"id":2,"name":"Bob"}]' \
        \\  | ./zig-out/bin/sql-pipe --validate -I json)
        \\expected='OK: 2 rows, 2 columns (id TEXT, name TEXT)'
        \\[ "$result" = "$expected" ]
    });
    test_validate_json.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_validate_json.step);

    // Integration test 80: --validate on valid NDJSON
    const test_validate_ndjson = b.addSystemCommand(&.{
        "bash", "-c",
        \\result=$(printf '{"id":1,"name":"Alice"}\n{"id":2,"name":"Bob"}\n' \
        \\  | ./zig-out/bin/sql-pipe --validate -I ndjson)
        \\expected='OK: 2 rows, 2 columns (id TEXT, name TEXT)'
        \\[ "$result" = "$expected" ]
    });
    test_validate_ndjson.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_validate_ndjson.step);

    // Integration test 81: --validate on invalid JSON exits 2
    const test_validate_json_error = b.addSystemCommand(&.{
        "bash", "-c",
        \\msg=$(printf '[{"id":1, broken}]' | ./zig-out/bin/sql-pipe --validate -I json 2>&1 >/dev/null; echo "EXIT:$?")
        \\echo "$msg" | grep -q 'EXIT:2'
    });
    test_validate_json_error.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_validate_json_error.step);

    // Integration test 82: --validate --output exits 1 with error
    const test_validate_output_conflict = b.addSystemCommand(&.{
        "bash", "-c",
        \\msg=$(printf 'a,b\n1,2\n' | ./zig-out/bin/sql-pipe --validate --output /tmp/x 2>&1 >/dev/null; echo "EXIT:$?")
        \\echo "$msg" | grep -q 'error: --output cannot be combined with --validate' && echo "$msg" | grep -q 'EXIT:1'
    });
    test_validate_output_conflict.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_validate_output_conflict.step);

    // Integration test 83: --validate --columns exits 1 with error
    const test_validate_columns_conflict = b.addSystemCommand(&.{
        "bash", "-c",
        \\msg=$(printf 'a,b\n1,2\n' | ./zig-out/bin/sql-pipe --validate --columns 2>&1 >/dev/null; echo "EXIT:$?")
        \\echo "$msg" | grep -q 'error: --validate cannot be combined with --columns' && echo "$msg" | grep -q 'EXIT:1'
    });
    test_validate_columns_conflict.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_validate_columns_conflict.step);

    // Integration test 84: --validate on invalid NDJSON exits 2
    const test_validate_ndjson_error = b.addSystemCommand(&.{
        "bash", "-c",
        \\msg=$(printf '{"id":1}\n{broken}\n' | ./zig-out/bin/sql-pipe --validate -I ndjson 2>&1 >/dev/null; echo "EXIT:$?")
        \\echo "$msg" | grep -q 'EXIT:2'
    });
    test_validate_ndjson_error.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_validate_ndjson_error.step);

    // ─── --sample integration tests ─────────────────────────────────────────

    // Integration test 85: --sample 3 outputs header + exactly 3 data rows to stdout
    const test_sample_row_count = b.addSystemCommand(&.{
        "bash", "-c",
        \\result=$(printf 'id,region,amount\n1,east,100\n2,west,200\n3,north,300\n4,south,400\n' \
        \\    | ./zig-out/bin/sql-pipe --sample 3 2>/dev/null)
        \\expected=$(printf 'id,region,amount\n1,east,100\n2,west,200\n3,north,300')
        \\[ "$result" = "$expected" ]
    });
    test_sample_row_count.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_sample_row_count.step);

    // Integration test 86: schema block goes to stderr, not stdout
    const test_sample_stdout_no_schema = b.addSystemCommand(&.{
        "bash", "-c",
        \\stdout=$(printf 'id,name\n1,Alice\n2,Bob\n' | ./zig-out/bin/sql-pipe --sample 1 2>/dev/null)
        \\echo "$stdout" | grep -qv '^#'
        \\echo "$stdout" | grep -q 'id,name'
    });
    test_sample_stdout_no_schema.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_sample_stdout_no_schema.step);

    // Integration test 87: schema block appears on stderr with correct header
    const test_sample_stderr_schema = b.addSystemCommand(&.{
        "bash", "-c",
        \\stderr=$(printf 'id,amount,name\n1,3.14,Alice\n' | ./zig-out/bin/sql-pipe --sample 1 2>&1 >/dev/null)
        \\echo "$stderr" | grep -q '^# Schema (3 columns):' \
        \\    && echo "$stderr" | grep -q 'id.*INTEGER' \
        \\    && echo "$stderr" | grep -q 'amount.*REAL' \
        \\    && echo "$stderr" | grep -q 'name.*TEXT'
    });
    test_sample_stderr_schema.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_sample_stderr_schema.step);

    // Integration test 88: --sample=n (equals syntax) works
    const test_sample_equals_syntax = b.addSystemCommand(&.{
        "bash", "-c",
        \\result=$(printf 'a,b\n1,2\n3,4\n5,6\n' | ./zig-out/bin/sql-pipe --sample=2 2>/dev/null)
        \\expected=$(printf 'a,b\n1,2\n3,4')
        \\[ "$result" = "$expected" ]
    });
    test_sample_equals_syntax.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_sample_equals_syntax.step);

    // Integration test 89: --sample 0 exits 1 with error message
    const test_sample_zero = b.addSystemCommand(&.{
        "bash", "-c",
        \\msg=$(printf 'a,b\n1,2\n' | ./zig-out/bin/sql-pipe --sample 0 2>&1 >/dev/null; echo "EXIT:$?")
        \\echo "$msg" | grep -q 'error:' && echo "$msg" | grep -q 'EXIT:1'
    });
    test_sample_zero.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_sample_zero.step);

    // Integration test 90: --sample with a non-file positional arg exits 2
    const test_sample_with_query = b.addSystemCommand(&.{
        "bash", "-c",
        \\msg=$(printf 'a,b\n1,2\n' | ./zig-out/bin/sql-pipe --sample 5 'SELECT * FROM t' 2>&1 >/dev/null; echo "EXIT:$?")
        \\echo "$msg" | grep -q 'error: cannot open file' && echo "$msg" | grep -q 'EXIT:2'
    });
    test_sample_with_query.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_sample_with_query.step);

    // Integration test 91: --sample combined with --output exits 1 with error
    const test_sample_with_output = b.addSystemCommand(&.{
        "bash", "-c",
        \\msg=$(printf 'a,b\n1,2\n' | ./zig-out/bin/sql-pipe --sample 5 --output /tmp/sp_test_out.csv 2>&1 >/dev/null; echo "EXIT:$?")
        \\echo "$msg" | grep -q 'error: --sample cannot be combined with --output' && echo "$msg" | grep -q 'EXIT:1'
    });
    test_sample_with_output.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_sample_with_output.step);

    // Integration test 92: --sample works with --tsv input (output uses tab delimiter)
    const test_sample_tsv = b.addSystemCommand(&.{
        "bash", "-c",
        \\result=$(printf 'a\tb\n1\t2\n3\t4\n' | ./zig-out/bin/sql-pipe --sample 1 --tsv 2>/dev/null)
        \\expected=$(printf 'a\tb\n1\t2')
        \\[ "$result" = "$expected" ]
    });
    test_sample_tsv.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_sample_tsv.step);

    // Integration test 93: --sample --no-type-inference shows all columns as TEXT
    const test_sample_no_type_inference = b.addSystemCommand(&.{
        "bash", "-c",
        \\stderr=$(printf 'id,amount\n1,3.14\n' | ./zig-out/bin/sql-pipe --sample 1 --no-type-inference 2>&1 >/dev/null)
        \\echo "$stderr" | grep -q 'id.*TEXT' && echo "$stderr" | grep -q 'amount.*TEXT'
    });
    test_sample_no_type_inference.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_sample_no_type_inference.step);

    // Integration test 94: --sample with fewer rows than n outputs only available rows
    const test_sample_fewer_rows = b.addSystemCommand(&.{
        "bash", "-c",
        \\result=$(printf 'x,y\n10,20\n' | ./zig-out/bin/sql-pipe --sample 50 2>/dev/null)
        \\expected=$(printf 'x,y\n10,20')
        \\[ "$result" = "$expected" ]
    });
    test_sample_fewer_rows.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_sample_fewer_rows.step);

    // Integration test 95: 2-char delimiter (||) splits fields correctly
    const test_delimiter_double_pipe = b.addSystemCommand(&.{
        "bash", "-c",
        \\printf 'name||age\nAlice||30\nBob||25\n' | ./zig-out/bin/sql-pipe --delimiter '||' 'SELECT name, age FROM t ORDER BY age' | diff - <(printf 'Bob,25\nAlice,30\n')
    });
    test_delimiter_double_pipe.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_delimiter_double_pipe.step);

    // Integration test 96: 3-char delimiter (;;;) splits fields correctly
    const test_delimiter_three_char = b.addSystemCommand(&.{
        "bash", "-c",
        \\printf 'name;;;age\nAlice;;;30\nBob;;;25\n' | ./zig-out/bin/sql-pipe --delimiter ';;;' 'SELECT name, age FROM t ORDER BY age' | diff - <(printf 'Bob,25\nAlice,30\n')
    });
    test_delimiter_three_char.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_delimiter_three_char.step);

    // Integration test 97: empty delimiter string exits 1 with error
    const test_delimiter_empty_error = b.addSystemCommand(&.{
        "bash", "-c",
        \\msg=$(printf 'a,b\n1,2\n' | ./zig-out/bin/sql-pipe -d '' 'SELECT * FROM t' 2>&1 >/dev/null; echo "EXIT:$?")
        \\echo "$msg" | grep -q 'EXIT:1'
    });
    test_delimiter_empty_error.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_delimiter_empty_error.step);

    // Integration test 98: delimiter longer than 8 chars exits 1 with error
    const test_delimiter_too_long_error = b.addSystemCommand(&.{
        "bash", "-c",
        \\msg=$(printf 'a,b\n1,2\n' | ./zig-out/bin/sql-pipe -d '123456789' 'SELECT * FROM t' 2>&1 >/dev/null; echo "EXIT:$?")
        \\echo "$msg" | grep -q 'EXIT:1'
    });
    test_delimiter_too_long_error.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_delimiter_too_long_error.step);

    // ─── XML input/output integration tests ─────────────────────────────────

    // Integration test 99: XML output format emits correct structure
    const test_xml_output = b.addSystemCommand(&.{
        "bash", "-c",
        \\result=$(printf 'name,age\nAlice,30\nBob,25\n' \
        \\    | ./zig-out/bin/sql-pipe --output-format xml 'SELECT * FROM t ORDER BY name')
        \\expected=$(printf '<?xml version="1.0" encoding="UTF-8"?>\n<results>\n<row><name>Alice</name><age>30</age></row>\n<row><name>Bob</name><age>25</age></row>\n</results>')
        \\[ "$result" = "$expected" ]
    });
    test_xml_output.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_xml_output.step);

    // Integration test 100: XML input can be queried
    const test_xml_input = b.addSystemCommand(&.{
        "bash", "-c",
        \\result=$(printf '<?xml version="1.0"?>\n<results>\n<row><name>Alice</name><age>30</age></row>\n<row><name>Bob</name><age>25</age></row>\n</results>\n' \
        \\    | ./zig-out/bin/sql-pipe --input-format xml 'SELECT name FROM t ORDER BY name')
        \\expected=$(printf 'Alice\nBob')
        \\[ "$result" = "$expected" ]
    });
    test_xml_input.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_xml_input.step);

    // Integration test 101: XML roundtrip (xml in → xml out)
    const test_xml_roundtrip = b.addSystemCommand(&.{
        "bash", "-c",
        \\result=$(printf '<?xml version="1.0"?>\n<results>\n<row><name>Alice</name><age>30</age></row>\n</results>\n' \
        \\    | ./zig-out/bin/sql-pipe -I xml -O xml 'SELECT * FROM t')
        \\echo "$result" | grep -q '<name>Alice</name>' && echo "$result" | grep -q '<age>30</age>'
    });
    test_xml_roundtrip.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_xml_roundtrip.step);

    // Integration test 102: --columns with XML input lists column names
    const test_xml_columns = b.addSystemCommand(&.{
        "bash", "-c",
        \\result=$(printf '<?xml version="1.0"?>\n<results>\n<row><name>Alice</name><age>30</age></row>\n</results>\n' \
        \\    | ./zig-out/bin/sql-pipe -I xml --columns)
        \\expected=$(printf 'name\nage')
        \\[ "$result" = "$expected" ]
    });
    test_xml_columns.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_xml_columns.step);

    // Integration test 103: --validate with XML input prints summary
    const test_xml_validate = b.addSystemCommand(&.{
        "bash", "-c",
        \\result=$(printf '<?xml version="1.0"?>\n<results>\n<row><name>Alice</name><age>30</age></row>\n<row><name>Bob</name><age>25</age></row>\n</results>\n' \
        \\    | ./zig-out/bin/sql-pipe -I xml --validate)
        \\echo "$result" | grep -q 'OK: 2 rows'
    });
    test_xml_validate.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_xml_validate.step);

    // Integration test 104: --xml-root and --xml-row customize element names for output
    const test_xml_custom_elements = b.addSystemCommand(&.{
        "bash", "-c",
        // Output: custom element names appear in the XML
        \\result=$(printf 'name,age\nAlice,30\n' \
        \\    | ./zig-out/bin/sql-pipe -O xml --xml-root data --xml-row record 'SELECT * FROM t')
        \\echo "$result" | grep -q '<data>' && echo "$result" | grep -q '<record>' && echo "$result" | grep -q '</data>'
    });
    test_xml_custom_elements.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_xml_custom_elements.step);

    // Integration test 105: XML entities en input — roundtrip correcto
    const test_xml_entities_input = b.addSystemCommand(&.{
        "bash", "-c",
        \\result=$(printf '<?xml version="1.0"?>\n<results>\n<row><name>Alice &amp; Bob</name></row>\n</results>\n' \
        \\    | ./zig-out/bin/sql-pipe -I xml 'SELECT name FROM t')
        \\[ "$result" = "Alice & Bob" ]
    });
    test_xml_entities_input.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_xml_entities_input.step);

    // Integration test 106: NULL en output XML → elemento vacío, no "NULL"
    const test_xml_null_output = b.addSystemCommand(&.{
        "bash", "-c",
        \\result=$(printf 'name\nAlice\n' \
        \\    | ./zig-out/bin/sql-pipe -O xml 'SELECT name, NULL as age FROM t')
        \\echo "$result" | grep -q '<age></age>'
    });
    test_xml_null_output.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_xml_null_output.step);

    // Integration test 107: Empty XML document → no such table error (table not created)
    const test_xml_empty_input = b.addSystemCommand(&.{
        "bash", "-c",
        \\msg=$(printf '' | ./zig-out/bin/sql-pipe -I xml 'SELECT 1 FROM t' 2>&1; echo "EXIT:$?")
        \\echo "$msg" | grep -q 'no such table' && echo "$msg" | grep -q 'EXIT:3'
    });
    test_xml_empty_input.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_xml_empty_input.step);

    // Integration test 108: Root sin rows → error con "no row elements"
    const test_xml_no_rows = b.addSystemCommand(&.{
        "bash", "-c",
        \\msg=$(printf '<results></results>' | ./zig-out/bin/sql-pipe -I xml 'SELECT 1' 2>&1; echo "EXIT:$?")
        \\echo "$msg" | grep -q 'no row elements' && echo "$msg" | grep -qv 'EXIT:0'
    });
    test_xml_no_rows.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_xml_no_rows.step);

    // Integration test 109: --sample rechazado con XML → exit no-cero con mensaje claro
    const test_xml_sample_rejected = b.addSystemCommand(&.{
        "bash", "-c",
        \\msg=$(printf '<r><row><a>1</a></row></r>' | ./zig-out/bin/sql-pipe -I xml --sample 2>&1; echo "EXIT:$?")
        \\echo "$msg" | grep -q 'sample' && echo "$msg" | grep -qv 'EXIT:0'
    });
    test_xml_sample_rejected.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_xml_sample_rejected.step);

    // Integration test 110: Self-closing column → NULL en SQLite (SELECT devuelve vacío)
    const test_xml_self_closing_null = b.addSystemCommand(&.{
        "bash", "-c",
        \\result=$(printf '<?xml version="1.0"?>\n<results>\n<row><name/><age>30</age></row>\n</results>\n' \
        \\    | ./zig-out/bin/sql-pipe -I xml 'SELECT COALESCE(name, "NULL_VALUE") FROM t')
        \\[ "$result" = "NULL_VALUE" ]
    });
    test_xml_self_closing_null.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_xml_self_closing_null.step);

    // Integration test 111: Columnas en orden distinto entre rows → bind-by-name correcto
    const test_xml_column_order = b.addSystemCommand(&.{
        "bash", "-c",
        \\result=$(printf '<?xml version="1.0"?>\n<results>\n<row><name>Alice</name><age>30</age></row>\n<row><age>25</age><name>Bob</name></row>\n</results>\n' \
        \\    | ./zig-out/bin/sql-pipe -I xml 'SELECT name || ":" || age FROM t ORDER BY name')
        \\[ "$result" = "$(printf 'Alice:30\nBob:25')" ]
    });
    test_xml_column_order.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_xml_column_order.step);

    // Integration test 112: Atributos en elementos → ignorados, contenido preservado
    const test_xml_attrs_ignored = b.addSystemCommand(&.{
        "bash", "-c",
        \\result=$(printf '<?xml version="1.0"?>\n<results>\n<row id="1"><name class="primary">Alice</name></row>\n</results>\n' \
        \\    | ./zig-out/bin/sql-pipe -I xml 'SELECT name FROM t')
        \\[ "$result" = "Alice" ]
    });
    test_xml_attrs_ignored.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_xml_attrs_ignored.step);

    // Integration test 113: Float-as-integer → emitido como entero en XML
    const test_xml_float_as_int = b.addSystemCommand(&.{
        "bash", "-c",
        \\result=$(printf 'x\n1\n' | ./zig-out/bin/sql-pipe -O xml 'SELECT CAST(30.0 AS REAL) as val')
        \\echo "$result" | grep -q '<val>30</val>'
    });
    test_xml_float_as_int.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_xml_float_as_int.step);

    // Integration test 114: --xml-root navigates nested XML for input (RSS-like structure)
    const test_xml_nested_navigation = b.addSystemCommand(&.{
        "bash", "-c",
        // Feed with <feed><channel><item> structure; --xml-root channel --xml-row item
        // selects only item elements from inside channel, skipping <title> etc.
        \\doc='<feed><channel><title>My Feed</title><item><name>Alice</name><age>30</age></item><item><name>Bob</name><age>25</age></item></channel></feed>'
        \\result=$(printf '%s' "$doc" \
        \\    | ./zig-out/bin/sql-pipe -I xml --xml-root channel --xml-row item \
        \\    'SELECT name || ":" || age FROM t ORDER BY name')
        \\[ "$result" = "$(printf 'Alice:30\nBob:25')" ]
    });
    test_xml_nested_navigation.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_xml_nested_navigation.step);

    // Integration test 115: --xml-root / --xml-row with --validate counts only matching rows
    const test_xml_nested_validate = b.addSystemCommand(&.{
        "bash", "-c",
        \\doc='<feed><channel><title>T</title><item><val>1</val></item><item><val>2</val></item></channel></feed>'
        \\result=$(printf '%s' "$doc" \
        \\    | ./zig-out/bin/sql-pipe -I xml --xml-root channel --xml-row item --validate)
        \\echo "$result" | grep -q 'OK: 2 rows'
    });
    test_xml_nested_validate.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_xml_nested_validate.step);

    // Integration test 116: --xml-root alone (no --xml-row) navigates to container
    const test_xml_root_alone = b.addSystemCommand(&.{
        "bash", "-c",
        \\doc='<feed><data><row><name>Alice</name></row><row><name>Bob</name></row></data></feed>'
        \\result=$(printf '%s' "$doc" \
        \\    | ./zig-out/bin/sql-pipe -I xml --xml-root data 'SELECT name FROM t ORDER BY name')
        \\[ "$result" = "$(printf 'Alice\nBob')" ]
    });
    test_xml_root_alone.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_xml_root_alone.step);

    // Integration test 117: --xml-row alone (no --xml-root) filters rows by tag
    const test_xml_row_alone = b.addSystemCommand(&.{
        "bash", "-c",
        \\doc='<results><item><name>Alice</name></item><meta><x>1</x></meta><item><name>Bob</name></item></results>'
        \\result=$(printf '%s' "$doc" \
        \\    | ./zig-out/bin/sql-pipe -I xml --xml-row item 'SELECT name FROM t ORDER BY name')
        \\[ "$result" = "$(printf 'Alice\nBob')" ]
    });
    test_xml_row_alone.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_xml_row_alone.step);

    // Integration test 118: --xml-row with no matching elements exits non-zero with clear message
    const test_xml_row_no_match = b.addSystemCommand(&.{
        "bash", "-c",
        \\msg=$(printf '<results><row><name>Alice</name></row></results>' \
        \\    | ./zig-out/bin/sql-pipe -I xml --xml-row wrong 'SELECT 1' 2>&1; echo "EXIT:$?")
        \\echo "$msg" | grep -q "'wrong'" && echo "$msg" | grep -q 'check --xml-row' && echo "$msg" | grep -qv 'EXIT:0'
    });
    test_xml_row_no_match.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_xml_row_no_match.step);

    // Integration test 119: --columns with --xml-root and --xml-row
    const test_xml_columns_with_flags = b.addSystemCommand(&.{
        "bash", "-c",
        \\doc='<feed><channel><item><name>Alice</name><age>30</age></item></channel></feed>'
        \\result=$(printf '%s' "$doc" \
        \\    | ./zig-out/bin/sql-pipe -I xml --xml-root channel --xml-row item --columns)
        \\[ "$result" = "$(printf 'name\nage')" ]
    });
    test_xml_columns_with_flags.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_xml_columns_with_flags.step);

    // Integration test 120: --xml-root matching the actual document root (fast path)
    const test_xml_root_fast_path = b.addSystemCommand(&.{
        "bash", "-c",
        \\result=$(printf '<results><row><name>Alice</name></row></results>' \
        \\    | ./zig-out/bin/sql-pipe -I xml --xml-root results 'SELECT name FROM t')
        \\[ "$result" = "Alice" ]
    });
    test_xml_root_fast_path.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_xml_root_fast_path.step);

    // Integration test 121: --disk produces correct output for CSV input
    const test_disk_csv = b.addSystemCommand(&.{
        "bash", "-c",
        \\result=$(printf 'name,age\nAlice,30\nBob,25\nCarol,35' \
        \\    | ./zig-out/bin/sql-pipe --disk 'SELECT name FROM t WHERE age > 27 ORDER BY name')
        \\[ "$result" = "$(printf 'Alice\nCarol')" ]
    });
    test_disk_csv.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_disk_csv.step);

    // Integration test 122: --disk produces same results as in-memory for aggregates
    const test_disk_aggregate = b.addSystemCommand(&.{
        "bash", "-c",
        \\result=$(printf 'item,price\nA,9.99\nB,3.00\nC,12.50\n' \
        \\    | ./zig-out/bin/sql-pipe --disk 'SELECT max(price), min(price) FROM t')
        \\[ "$result" = "12.5,3.0" ]
    });
    test_disk_aggregate.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_disk_aggregate.step);

    // Integration test 123: --disk with ORDER BY (exercises PRAGMA temp_store = FILE)
    const test_disk_order_by = b.addSystemCommand(&.{
        "bash", "-c",
        \\result=$(printf 'name,score\nZara,90\nAna,85\nMike,92\n' \
        \\    | ./zig-out/bin/sql-pipe --disk 'SELECT name FROM t ORDER BY score DESC')
        \\[ "$result" = "$(printf 'Mike\nZara\nAna')" ]
    });
    test_disk_order_by.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_disk_order_by.step);

    // Integration test 124: --disk with TSV input
    const test_disk_tsv = b.addSystemCommand(&.{
        "bash", "-c",
        \\result=$(printf 'name\tval\nFoo\t10\nBar\t20\n' \
        \\    | ./zig-out/bin/sql-pipe --disk --tsv 'SELECT name FROM t WHERE val > 15')
        \\[ "$result" = "Bar" ]
    });
    test_disk_tsv.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_disk_tsv.step);

    // Integration test 125: --disk with NDJSON input
    // age column is TEXT (NDJSON uses createAllTextTable); comparison works via
    // SQLite implicit TEXT→NUMERIC conversion when compared against a numeric literal.
    const test_disk_ndjson = b.addSystemCommand(&.{
        "bash", "-c",
        \\result=$(printf '{"name":"Alice","age":30}\n{"name":"Bob","age":25}\n' \
        \\    | ./zig-out/bin/sql-pipe --disk -I ndjson 'SELECT name FROM t WHERE age > 27')
        \\[ "$result" = "Alice" ]
    });
    test_disk_ndjson.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_disk_ndjson.step);

    // Integration test 126: --disk with JSON input
    // age column is TEXT (JSON uses createAllTextTable); comparison works via
    // SQLite implicit TEXT→NUMERIC conversion when compared against a numeric literal.
    const test_disk_json = b.addSystemCommand(&.{
        "bash", "-c",
        \\result=$(printf '[{"name":"Alice","age":30},{"name":"Bob","age":25}]' \
        \\    | ./zig-out/bin/sql-pipe --disk -I json 'SELECT name FROM t WHERE age > 27')
        \\[ "$result" = "Alice" ]
    });
    test_disk_json.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_disk_json.step);

    // Integration test 127: --disk with XML input
    // age column is TEXT (XML uses createAllTextTable); comparison works via
    // SQLite implicit TEXT→NUMERIC conversion when compared against a numeric literal.
    const test_disk_xml = b.addSystemCommand(&.{
        "bash", "-c",
        \\result=$(printf '<data><row><name>Alice</name><age>30</age></row><row><name>Bob</name><age>25</age></row></data>' \
        \\    | ./zig-out/bin/sql-pipe --disk -I xml 'SELECT name FROM t WHERE age > 27')
        \\[ "$result" = "Alice" ]
    });
    test_disk_xml.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_disk_xml.step);

    // Integration test 128: --disk with GROUP BY
    const test_disk_group_by = b.addSystemCommand(&.{
        "bash", "-c",
        \\result=$(printf 'region,revenue\nEast,100\nWest,200\nEast,150\nWest,50\n' \
        \\    | ./zig-out/bin/sql-pipe --disk 'SELECT region, SUM(revenue) FROM t GROUP BY region ORDER BY region')
        \\[ "$result" = "$(printf 'East,250\nWest,250')" ]
    });
    test_disk_group_by.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_disk_group_by.step);

    // Integration test 129: --disk with --no-type-inference (all TEXT columns)
    // Uses SQLite implicit TEXT→NUMERIC conversion for the numeric comparison.
    const test_disk_no_type_inference = b.addSystemCommand(&.{
        "bash", "-c",
        \\result=$(printf 'name,age\nAlice,30\nBob,25\nCarol,35' \
        \\    | ./zig-out/bin/sql-pipe --disk --no-type-inference \
        \\    'SELECT name FROM t WHERE age > 27 ORDER BY name')
        \\[ "$result" = "$(printf 'Alice\nCarol')" ]
    });
    test_disk_no_type_inference.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_disk_no_type_inference.step);

    // Integration test 130: --disk with --header outputs column names in first row
    const test_disk_header = b.addSystemCommand(&.{
        "bash", "-c",
        \\result=$(printf 'name,age\nAlice,30\nBob,25\n' \
        \\    | ./zig-out/bin/sql-pipe --disk --header 'SELECT name, age FROM t ORDER BY age')
        \\[ "$result" = "$(printf 'name,age\nBob,25\nAlice,30')" ]
    });
    test_disk_header.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_disk_header.step);

    // Integration test 131: --disk with --output writes results to file
    const test_disk_output = b.addSystemCommand(&.{
        "bash", "-c",
        \\tmp=$(mktemp)
        \\printf 'name,val\nA,10\nB,20\n' \
        \\    | ./zig-out/bin/sql-pipe --disk --output "$tmp" 'SELECT name FROM t WHERE val > 15'
        \\result=$(cat "$tmp")
        \\rm -f "$tmp"
        \\[ "$result" = "B" ]
    });
    test_disk_output.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_disk_output.step);

    // Integration test 132: mismatched nested closing tag in XML column content → non-zero exit
    const test_xml_mismatched_tags = b.addSystemCommand(&.{
        "bash", "-c",
        \\printf '<r><row><col><a>text</b></col></row></r>' \
        \\    | ./zig-out/bin/sql-pipe -I xml 'SELECT * FROM t' 2>/dev/null; test $? -ne 0
    });
    test_xml_mismatched_tags.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_xml_mismatched_tags.step);

    // Integration test 133: --json-path navigates single-key nested JSON array
    const test_json_path_single = b.addSystemCommand(&.{
        "bash", "-c",
        \\result=$(printf '{"data":[{"name":"Alice"},{"name":"Bob"}]}' \
        \\    | ./zig-out/bin/sql-pipe -I json --json-path data 'SELECT name FROM t ORDER BY name')
        \\[ "$result" = "$(printf 'Alice\nBob')" ]
    });
    test_json_path_single.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_json_path_single.step);

    // Integration test 134: --json-path navigates multi-segment nested JSON path
    const test_json_path_multi = b.addSystemCommand(&.{
        "bash", "-c",
        \\result=$(printf '{"results":{"items":[{"id":1},{"id":2}]}}' \
        \\    | ./zig-out/bin/sql-pipe -I json --json-path results.items 'SELECT id FROM t ORDER BY id')
        \\[ "$result" = "$(printf '1\n2')" ]
    });
    test_json_path_multi.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_json_path_multi.step);

    // Integration test 135: --json-path with missing key exits non-zero
    const test_json_path_missing_key = b.addSystemCommand(&.{
        "bash", "-c",
        \\printf '{"data":[{"name":"Alice"}]}' \
        \\    | ./zig-out/bin/sql-pipe -I json --json-path missing 'SELECT * FROM t' 2>/dev/null; test $? -ne 0
    });
    test_json_path_missing_key.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_json_path_missing_key.step);

    // Integration test 136: --json-path targeting a non-array value exits non-zero
    const test_json_path_non_array = b.addSystemCommand(&.{
        "bash", "-c",
        \\printf '{"data":{"name":"Alice"}}' \
        \\    | ./zig-out/bin/sql-pipe -I json --json-path data 'SELECT * FROM t' 2>/dev/null; test $? -ne 0
    });
    test_json_path_non_array.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_json_path_non_array.step);

    // Integration test 137: --json-path with --columns lists columns from nested array
    const test_json_path_columns = b.addSystemCommand(&.{
        "bash", "-c",
        \\result=$(printf '{"feed":{"entry":[{"title":"T1","link":"L1"}]}}' \
        \\    | ./zig-out/bin/sql-pipe -I json --json-path feed.entry --columns)
        \\[ "$result" = "$(printf 'title\nlink')" ]
    });
    test_json_path_columns.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_json_path_columns.step);

    // Integration test 138: --json-path with --validate parses nested JSON array and prints summary
    const test_json_path_validate = b.addSystemCommand(&.{
        "bash", "-c",
        \\result=$(printf '{"data":[{"id":1,"name":"Alice"},{"id":2,"name":"Bob"}]}' \
        \\    | ./zig-out/bin/sql-pipe -I json --json-path data --validate)
        \\echo "$result" | grep -q "OK: 2 rows"
    });
    test_json_path_validate.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_json_path_validate.step);

    // Integration test 139: --json-path with non-json input format exits non-zero
    const test_json_path_format_mismatch = b.addSystemCommand(&.{
        "bash", "-c",
        \\printf 'name\nAlice\n' \
        \\    | ./zig-out/bin/sql-pipe -I csv --json-path data 'SELECT * FROM t' 2>/dev/null; test $? -ne 0
    });
    test_json_path_format_mismatch.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_json_path_format_mismatch.step);

    // ─── Date / datetime type inference integration tests ────────────────────

    // Integration test 140: ISO date column is stored and queryable as YYYY-MM-DD text
    const test_date_iso = b.addSystemCommand(&.{
        "bash", "-c",
        \\result=$(printf 'id,dob\n1,2024-01-15\n2,1999-12-31\n' \
        \\    | ./zig-out/bin/sql-pipe "SELECT dob FROM t WHERE id=1")
        \\[ "$result" = "2024-01-15" ]
    });
    test_date_iso.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_date_iso.step);

    // Integration test 141: ISO date column supports SQLite date() function
    const test_date_iso_func = b.addSystemCommand(&.{
        "bash", "-c",
        \\result=$(printf 'id,dob\n1,2024-01-15\n' \
        \\    | ./zig-out/bin/sql-pipe "SELECT date(dob) FROM t")
        \\[ "$result" = "2024-01-15" ]
    });
    test_date_iso_func.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_date_iso_func.step);

    // Integration test 142: EU-dash date (DD-MM-YYYY) normalized to ISO on insert
    const test_date_eu_dash = b.addSystemCommand(&.{
        "bash", "-c",
        \\result=$(printf 'id,dob\n1,15-01-2024\n2,31-12-1999\n' \
        \\    | ./zig-out/bin/sql-pipe "SELECT dob FROM t ORDER BY dob")
        \\expected=$(printf '1999-12-31\n2024-01-15')
        \\[ "$result" = "$expected" ]
    });
    test_date_eu_dash.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_date_eu_dash.step);

    // Integration test 143: EU-slash date (DD/MM/YYYY) detected when d1 > 12
    const test_date_eu_slash = b.addSystemCommand(&.{
        "bash", "-c",
        \\result=$(printf 'id,dob\n1,15/01/2024\n2,31/12/1999\n' \
        \\    | ./zig-out/bin/sql-pipe "SELECT dob FROM t ORDER BY dob")
        \\expected=$(printf '1999-12-31\n2024-01-15')
        \\[ "$result" = "$expected" ]
    });
    test_date_eu_slash.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_date_eu_slash.step);

    // Integration test 144: US-slash date (MM/DD/YYYY) detected when d2 > 12
    const test_date_us_slash = b.addSystemCommand(&.{
        "bash", "-c",
        \\result=$(printf 'id,dob\n1,01/15/2024\n2,12/31/1999\n' \
        \\    | ./zig-out/bin/sql-pipe "SELECT dob FROM t ORDER BY dob")
        \\expected=$(printf '1999-12-31\n2024-01-15')
        \\[ "$result" = "$expected" ]
    });
    test_date_us_slash.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_date_us_slash.step);

    // Integration test 145: ambiguous slash date (both ≤ 12) → TEXT, no normalization
    const test_date_slash_ambiguous = b.addSystemCommand(&.{
        "bash", "-c",
        \\result=$(printf 'id,dob\n1,05/06/2024\n' \
        \\    | ./zig-out/bin/sql-pipe "SELECT dob FROM t")
        \\[ "$result" = "05/06/2024" ]
    });
    test_date_slash_ambiguous.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_date_slash_ambiguous.step);

    // Integration test 146: ISO datetime (space separator) stored as ISO and queryable
    const test_datetime_iso_space = b.addSystemCommand(&.{
        "bash", "-c",
        \\result=$(printf 'id,ts\n1,2024-01-15 10:30:00\n' \
        \\    | ./zig-out/bin/sql-pipe "SELECT ts FROM t")
        \\[ "$result" = "2024-01-15 10:30:00" ]
    });
    test_datetime_iso_space.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_datetime_iso_space.step);

    // Integration test 147: ISO datetime T-separator normalized to space on insert
    const test_datetime_iso_t = b.addSystemCommand(&.{
        "bash", "-c",
        \\result=$(printf 'id,ts\n1,2024-01-15T10:30:00\n' \
        \\    | ./zig-out/bin/sql-pipe "SELECT ts FROM t")
        \\[ "$result" = "2024-01-15 10:30:00" ]
    });
    test_datetime_iso_t.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_datetime_iso_t.step);

    // Integration test 148: EU-slash datetime (DD/MM/YYYY HH:MM) normalized to ISO
    const test_datetime_eu_slash = b.addSystemCommand(&.{
        "bash", "-c",
        \\result=$(printf 'id,ts\n1,15/01/2024 10:30\n' \
        \\    | ./zig-out/bin/sql-pipe "SELECT ts FROM t")
        \\[ "$result" = "2024-01-15 10:30:00" ]
    });
    test_datetime_eu_slash.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_datetime_eu_slash.step);

    // Integration test 149: US-slash datetime (MM/DD/YYYY HH:MM) normalized to ISO
    const test_datetime_us_slash = b.addSystemCommand(&.{
        "bash", "-c",
        \\result=$(printf 'id,ts\n1,01/15/2024 10:30\n' \
        \\    | ./zig-out/bin/sql-pipe "SELECT ts FROM t")
        \\[ "$result" = "2024-01-15 10:30:00" ]
    });
    test_datetime_us_slash.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_datetime_us_slash.step);

    // Integration test 150: --columns --verbose shows DATE for date column
    const test_columns_date_type = b.addSystemCommand(&.{
        "bash", "-c",
        \\result=$(printf 'id,dob\n1,2024-01-15\n' \
        \\    | ./zig-out/bin/sql-pipe --columns --verbose)
        \\echo "$result" | grep -q "dob DATE"
    });
    test_columns_date_type.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_columns_date_type.step);

    // Integration test 151: --columns --verbose shows DATETIME for datetime column
    const test_columns_datetime_type = b.addSystemCommand(&.{
        "bash", "-c",
        \\result=$(printf 'id,ts\n1,2024-01-15 10:30:00\n' \
        \\    | ./zig-out/bin/sql-pipe --columns --verbose)
        \\echo "$result" | grep -q "ts DATETIME"
    });
    test_columns_datetime_type.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_columns_datetime_type.step);

    // Integration test 152: --validate shows DATE in schema summary
    const test_validate_date_type = b.addSystemCommand(&.{
        "bash", "-c",
        \\result=$(printf 'id,dob\n1,2024-01-15\n2,1999-12-31\n' \
        \\    | ./zig-out/bin/sql-pipe --validate)
        \\echo "$result" | grep -q "dob DATE"
    });
    test_validate_date_type.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_validate_date_type.step);

    // Integration test 153: date column supports ORDER BY (ISO sort = chronological)
    const test_date_order_by = b.addSystemCommand(&.{
        "bash", "-c",
        \\result=$(printf 'name,dob\nBob,15-01-1990\nAlice,20-03-1985\nCarol,01-07-1992\n' \
        \\    | ./zig-out/bin/sql-pipe "SELECT name FROM t ORDER BY dob")
        \\expected=$(printf 'Alice\nBob\nCarol')
        \\[ "$result" = "$expected" ]
    });
    test_date_order_by.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_date_order_by.step);

    // Integration test 154: --no-type-inference keeps date as TEXT (no normalization)
    const test_date_no_type_inference = b.addSystemCommand(&.{
        "bash", "-c",
        \\result=$(printf 'id,dob\n1,15/01/2024\n' \
        \\    | ./zig-out/bin/sql-pipe --no-type-inference "SELECT dob FROM t")
        \\[ "$result" = "15/01/2024" ]
    });
    test_date_no_type_inference.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_date_no_type_inference.step);
    // ─── File argument integration tests (issue #155) ───────────────────────

    // Integration test 155a: Single file argument — query by table name
    const test_file_single = b.addSystemCommand(&.{
        "bash", "-c",
        \\dir=$(mktemp -d)
        \\printf 'name,amount\nAlice,150\nBob,80\nCarol,200\n' > "$dir/orders.csv"
        \\result=$(./zig-out/bin/sql-pipe "$dir/orders.csv" 'SELECT name FROM orders WHERE amount > 100')
        \\rm -rf "$dir"
        \\[ "$result" = "$(printf 'Alice\nCarol')" ]
    });
    test_file_single.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_file_single.step);

    // Integration test 155b: Multi-file join
    const test_file_multi_join = b.addSystemCommand(&.{
        "bash", "-c",
        \\dir=$(mktemp -d)
        \\printf 'id,name\n1,Alice\n2,Bob\n3,Carol\n' > "$dir/users.csv"
        \\printf 'user_id,amount\n1,150\n2,80\n3,200\n1,50\n' > "$dir/orders.csv"
        \\result=$(./zig-out/bin/sql-pipe "$dir/users.csv" "$dir/orders.csv" \
        \\    'SELECT u.name, SUM(o.amount) FROM users u JOIN orders o ON u.id = o.user_id GROUP BY u.name ORDER BY u.name')
        \\rm -rf "$dir"
        \\expected=$(printf 'Alice,200\nBob,80\nCarol,200')
        \\[ "$result" = "$expected" ]
    });
    test_file_multi_join.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_file_multi_join.step);

    // Integration test 155c: Stdin + file mix
    const test_file_stdin_mix = b.addSystemCommand(&.{
        "bash", "-c",
        \\dir=$(mktemp -d)
        \\printf 'uid,name\n1,Alice\n2,Bob\n' > "$dir/users.csv"
        \\result=$(printf 'user_id,amount\n1,150\n2,80\n' \
        \\    | ./zig-out/bin/sql-pipe "$dir/users.csv" 'SELECT t.amount, u.name FROM t JOIN users u ON t.user_id = u.uid ORDER BY u.name')
        \\rm -rf "$dir"
        \\[ "$result" = "$(printf '150,Alice\n80,Bob')" ]
    });
    test_file_stdin_mix.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_file_stdin_mix.step);

    // Integration test 155d: File with .tsv extension auto-detected as TSV
    const test_file_tsv_ext = b.addSystemCommand(&.{
        "bash", "-c",
        \\dir=$(mktemp -d)
        \\printf 'name\tage\nAlice\t30\nBob\t25\n' > "$dir/data.tsv"
        \\result=$(./zig-out/bin/sql-pipe "$dir/data.tsv" 'SELECT name FROM data WHERE age > 27')
        \\rm -rf "$dir"
        \\[ "$result" = "Alice" ]
    });
    test_file_tsv_ext.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_file_tsv_ext.step);

    // Integration test 155e: -- separator works
    const test_file_dashdash = b.addSystemCommand(&.{
        "bash", "-c",
        \\dir=$(mktemp -d)
        \\printf 'x,y\n1,2\n' > "$dir/data.csv"
        \\result=$(./zig-out/bin/sql-pipe -- "$dir/data.csv" 'SELECT y FROM data')
        \\rm -rf "$dir"
        \\[ "$result" = "2" ]
    });
    test_file_dashdash.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_file_dashdash.step);

    // Integration test 155f: Non-existent file argument exits 2
    const test_file_not_found = b.addSystemCommand(&.{
        "bash", "-c",
        \\msg=$(./zig-out/bin/sql-pipe /tmp/nonexistent_file_xyz.csv 'SELECT * FROM t' 2>&1 >/dev/null; echo "EXIT:$?")
        \\echo "$msg" | grep -q 'error: cannot open file' && echo "$msg" | grep -q 'EXIT:2'
    });
    test_file_not_found.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_file_not_found.step);

    // Integration test 155g: File with no extension uses default CSV format
    const test_file_no_ext = b.addSystemCommand(&.{
        "bash", "-c",
        \\dir=$(mktemp -d)
        \\printf 'name,age\nAlice,30\n' > "$dir/mydata"
        \\result=$(./zig-out/bin/sql-pipe "$dir/mydata" 'SELECT name FROM mydata')
        \\rm -rf "$dir"
        \\[ "$result" = "Alice" ]
    });
    test_file_no_ext.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_file_no_ext.step);

    // Integration test 155h: Stdin still works as `t` (existing behavior preserved)
    const test_file_stdin_only = b.addSystemCommand(&.{
        "bash", "-c",
        \\result=$(printf 'name,age\nAlice,30\nBob,25\n' \
        \\    | ./zig-out/bin/sql-pipe 'SELECT name FROM t WHERE age > 27')
        \\[ "$result" = "Alice" ]
    });
    test_file_stdin_only.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_file_stdin_only.step);

    // Integration test 155i: No file args + no stdin + no query → error
    const test_file_no_input = b.addSystemCommand(&.{
        "bash", "-c",
        \\msg=$(./zig-out/bin/sql-pipe 2>&1 >/dev/null; echo "EXIT:$?")
        \\echo "$msg" | grep -q 'Usage:' && echo "$msg" | grep -q 'EXIT:1'
    });
    test_file_no_input.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_file_no_input.step);

    // Integration test 155j: File named t.csv conflicts with stdin table t
    const test_file_t_conflict = b.addSystemCommand(&.{
        "bash", "-c",
        \\dir=$(mktemp -d)
        \\printf 'a,b\n1,2\n' > "$dir/t.csv"
        \\msg=$(printf 'x,y\n3,4\n' | ./zig-out/bin/sql-pipe "$dir/t.csv" 'SELECT * FROM t' 2>&1 >/dev/null; echo "EXIT:$?")
        \\rm -rf "$dir"
        \\echo "$msg" | grep -q 'duplicate table name' && echo "$msg" | grep -q 'EXIT:1'
    });
    test_file_t_conflict.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_file_t_conflict.step);

    // ─── -f/--file flag integration tests (issue #157) ────────────────────────

    // Integration test 157a: -f reads query from file, file arg for data
    const test_f_flag_basic = b.addSystemCommand(&.{
        "bash", "-c",
        \\dir=$(mktemp -d)
        \\printf 'name,age\nAlice,30\nBob,25\nCarol,35' > "$dir/data.csv"
        \\printf 'SELECT name FROM data WHERE age > 27' > "$dir/query.sql"
        \\result=$(./zig-out/bin/sql-pipe -f "$dir/query.sql" "$dir/data.csv")
        \\rm -rf "$dir"
        \\[ "$result" = "$(printf 'Alice\nCarol')" ]
    });
    test_f_flag_basic.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_f_flag_basic.step);

    // Integration test 157b: -f with stdin input
    const test_f_flag_stdin = b.addSystemCommand(&.{
        "bash", "-c",
        \\dir=$(mktemp -d)
        \\printf 'SELECT name FROM t WHERE age > 27' > "$dir/query.sql"
        \\result=$(printf 'name,age\nAlice,30\nBob,25\nCarol,35' \
        \\    | ./zig-out/bin/sql-pipe -f "$dir/query.sql")
        \\rm -rf "$dir"
        \\[ "$result" = "$(printf 'Alice\nCarol')" ]
    });
    test_f_flag_stdin.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_f_flag_stdin.step);

    // Integration test 157c: --file long form
    const test_file_flag_long = b.addSystemCommand(&.{
        "bash", "-c",
        \\dir=$(mktemp -d)
        \\printf 'name,age\nAlice,30\nBob,25\nCarol,35' > "$dir/data.csv"
        \\printf 'SELECT name FROM data WHERE age > 27' > "$dir/query.sql"
        \\result=$(./zig-out/bin/sql-pipe --file "$dir/query.sql" "$dir/data.csv")
        \\rm -rf "$dir"
        \\[ "$result" = "$(printf 'Alice\nCarol')" ]
    });
    test_file_flag_long.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_file_flag_long.step);

    // Integration test 157d: --file= equals form
    const test_file_flag_equals = b.addSystemCommand(&.{
        "bash", "-c",
        \\dir=$(mktemp -d)
        \\printf 'name,age\nAlice,30\n' > "$dir/data.csv"
        \\printf 'SELECT name FROM data' > "$dir/query.sql"
        \\result=$(./zig-out/bin/sql-pipe --file="$dir/query.sql" "$dir/data.csv")
        \\rm -rf "$dir"
        \\[ "$result" = "Alice" ]
    });
    test_file_flag_equals.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_file_flag_equals.step);

    // Integration test 157e: -f= equals form
    const test_f_flag_eq = b.addSystemCommand(&.{
        "bash", "-c",
        \\dir=$(mktemp -d)
        \\printf 'name,age\nAlice,30\n' > "$dir/data.csv"
        \\printf 'SELECT name FROM data' > "$dir/query.sql"
        \\result=$(./zig-out/bin/sql-pipe -f="$dir/query.sql" "$dir/data.csv")
        \\rm -rf "$dir"
        \\[ "$result" = "Alice" ]
    });
    test_f_flag_eq.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_f_flag_eq.step);

    // Integration test 157f: Error case — file doesn't exist
    const test_f_flag_not_found = b.addSystemCommand(&.{
        "bash", "-c",
        \\msg=$(./zig-out/bin/sql-pipe -f /tmp/nonexistent_query_file.sql 2>&1 >/dev/null; echo "EXIT:$?")
        \\echo "$msg" | grep -q "cannot read query file" && echo "$msg" | grep -q 'EXIT:1'
    });
    test_f_flag_not_found.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_f_flag_not_found.step);

    // Integration test 157g: Error case — empty query file
    const test_f_flag_empty = b.addSystemCommand(&.{
        "bash", "-c",
        \\dir=$(mktemp -d)
        \\printf '' > "$dir/empty.sql"
        \\msg=$(./zig-out/bin/sql-pipe -f "$dir/empty.sql" 2>&1 >/dev/null; echo "EXIT:$?")
        \\rm -rf "$dir"
        \\echo "$msg" | grep -q "query file.*is empty" && echo "$msg" | grep -q 'EXIT:1'
    });
    test_f_flag_empty.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_f_flag_empty.step);

    // Integration test 157h: Error case — whitespace-only query file
    const test_f_flag_whitespace = b.addSystemCommand(&.{
        "bash", "-c",
        \\dir=$(mktemp -d)
        \\printf '  \n\t  \n' > "$dir/ws.sql"
        \\msg=$(./zig-out/bin/sql-pipe -f "$dir/ws.sql" 2>&1 >/dev/null; echo "EXIT:$?")
        \\rm -rf "$dir"
        \\echo "$msg" | grep -q "query file.*is empty" && echo "$msg" | grep -q 'EXIT:1'
    });
    test_f_flag_whitespace.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_f_flag_whitespace.step);

    // Integration test 157i: Error case — -f with --columns
    const test_f_flag_columns = b.addSystemCommand(&.{
        "bash", "-c",
        \\dir=$(mktemp -d)
        \\printf 'SELECT 1' > "$dir/q.sql"
        \\printf 'name,age\nAlice,30' > "$dir/data.csv"
        \\msg=$(./zig-out/bin/sql-pipe --columns -f "$dir/q.sql" "$dir/data.csv" 2>&1 >/dev/null; echo "EXIT:$?")
        \\rm -rf "$dir"
        \\echo "$msg" | grep -q "cannot be combined with" && echo "$msg" | grep -q 'EXIT:1'
    });
    test_f_flag_columns.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_f_flag_columns.step);

    // Integration test 157j: Error case — -f with --validate
    const test_f_flag_validate = b.addSystemCommand(&.{
        "bash", "-c",
        \\dir=$(mktemp -d)
        \\printf 'SELECT 1' > "$dir/q.sql"
        \\printf 'name,age\nAlice,30' > "$dir/data.csv"
        \\msg=$(./zig-out/bin/sql-pipe --validate -f "$dir/q.sql" "$dir/data.csv" 2>&1 >/dev/null; echo "EXIT:$?")
        \\rm -rf "$dir"
        \\echo "$msg" | grep -q "cannot be combined with" && echo "$msg" | grep -q 'EXIT:1'
    });
    test_f_flag_validate.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_f_flag_validate.step);

    // Integration test 157k: Error case — -f with --sample
    const test_f_flag_sample = b.addSystemCommand(&.{
        "bash", "-c",
        \\dir=$(mktemp -d)
        \\printf 'SELECT 1' > "$dir/q.sql"
        \\printf 'name,age\nAlice,30' > "$dir/data.csv"
        \\msg=$(./zig-out/bin/sql-pipe --sample -f "$dir/q.sql" "$dir/data.csv" 2>&1 >/dev/null; echo "EXIT:$?")
        \\rm -rf "$dir"
        \\echo "$msg" | grep -q "cannot be combined with" && echo "$msg" | grep -q 'EXIT:1'
    });
    test_f_flag_sample.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_f_flag_sample.step);

    // Integration test 157l: Error case — multiple -f flags
    const test_f_flag_multiple = b.addSystemCommand(&.{
        "bash", "-c",
        \\dir=$(mktemp -d)
        \\printf 'SELECT 1' > "$dir/q1.sql"
        \\printf 'SELECT 2' > "$dir/q2.sql"
        \\msg=$(./zig-out/bin/sql-pipe -f "$dir/q1.sql" -f "$dir/q2.sql" 2>&1 >/dev/null; echo "EXIT:$?")
        \\rm -rf "$dir"
        \\echo "$msg" | grep -q "only one -f/--file" && echo "$msg" | grep -q 'EXIT:1'
    });
    test_f_flag_multiple.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_f_flag_multiple.step);

    // ─── --schema integration tests (issue #176) ──────────────────────────────

    // Integration test 176a: --schema on CSV stdin prints CREATE TABLE DDL
    const test_schema_stdin = b.addSystemCommand(&.{
        "bash", "-c",
        \\result=$(printf 'name,age\nAlice,30\nBob,25\n' | ./zig-out/bin/sql-pipe --schema)
        \\echo "$result" | grep -q 'CREATE TABLE "t"'
    });
    test_schema_stdin.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_schema_stdin.step);

    // Integration test 176b: --schema shows inferred column types
    const test_schema_types = b.addSystemCommand(&.{
        "bash", "-c",
        \\result=$(printf 'id,name,amount,ts\n1,Alice,3.14,2024-01-15\n' | ./zig-out/bin/sql-pipe --schema)
        \\echo "$result" | grep -q '"id" INTEGER' && echo "$result" | grep -q '"name" TEXT' && echo "$result" | grep -q '"amount" REAL' && echo "$result" | grep -q '"ts" TEXT'
    });
    test_schema_types.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_schema_types.step);

    // Integration test 176c: --schema outputs semicolon-terminated DDL
    const test_schema_semicolon = b.addSystemCommand(&.{
        "bash", "-c",
        \\result=$(printf 'x,y\n1,2\n' | ./zig-out/bin/sql-pipe --schema)
        \\echo "$result" | grep -q ';$'
    });
    test_schema_semicolon.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_schema_semicolon.step);

    // Integration test 176d: --schema with single file argument
    const test_schema_file = b.addSystemCommand(&.{
        "bash", "-c",
        \\dir=$(mktemp -d)
        \\printf 'name,age\nAlice,30\n' > "$dir/data.csv"
        \\result=$(./zig-out/bin/sql-pipe "$dir/data.csv" --schema)
        \\rm -rf "$dir"
        \\echo "$result" | grep -q 'CREATE TABLE "data"'
    });
    test_schema_file.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_schema_file.step);

    // Integration test 176e: --schema with multiple file arguments
    const test_schema_multi_file = b.addSystemCommand(&.{
        "bash", "-c",
        \\dir=$(mktemp -d)
        \\printf 'id,name\n1,Alice\n' > "$dir/a.csv"
        \\printf 'id,val\n1,100\n' > "$dir/b.csv"
        \\result=$(./zig-out/bin/sql-pipe "$dir/a.csv" "$dir/b.csv" --schema)
        \\rm -rf "$dir"
        \\echo "$result" | grep -q 'CREATE TABLE "a"' && echo "$result" | grep -q 'CREATE TABLE "b"'
    });
    test_schema_multi_file.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_schema_multi_file.step);

    // Integration test 176f: --schema with --no-type-inference shows all TEXT
    const test_schema_no_type_inference = b.addSystemCommand(&.{
        "bash", "-c",
        \\result=$(printf 'id,amount\n1,3.14\n' | ./zig-out/bin/sql-pipe --schema --no-type-inference)
        \\echo "$result" | grep -q '"id" TEXT' && echo "$result" | grep -q '"amount" TEXT'
    });
    test_schema_no_type_inference.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_schema_no_type_inference.step);

    // Integration test 176f2: --schema on empty input exits non-zero
    const test_schema_empty = b.addSystemCommand(&.{
        "bash", "-c",
        \\msg=$(printf '' | ./zig-out/bin/sql-pipe --schema 2>&1 >/dev/null; echo "EXIT:$?")
        \\echo "$msg" | grep -q 'empty input' && echo "$msg" | grep -q 'EXIT:2'
    });
    test_schema_empty.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_schema_empty.step);

    // Integration test 176g: --schema with --tsv input
    const test_schema_tsv = b.addSystemCommand(&.{
        "bash", "-c",
        \\result=$(printf 'name\tage\nAlice\t30\n' | ./zig-out/bin/sql-pipe --schema --tsv)
        \\echo "$result" | grep -q 'CREATE TABLE "t"' && echo "$result" | grep -q '"age" INTEGER'
    });
    test_schema_tsv.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_schema_tsv.step);

    // Integration test 176h: --schema with JSON input (-I json)
    const test_schema_json = b.addSystemCommand(&.{
        "bash", "-c",
        \\result=$(printf '[{"name":"Alice","age":30}]' | ./zig-out/bin/sql-pipe --schema -I json)
        \\echo "$result" | grep -q 'CREATE TABLE "t"' && echo "$result" | grep -q '"name" TEXT' && echo "$result" | grep -q '"age" TEXT'
    });
    test_schema_json.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_schema_json.step);

    // Integration test 176i: --schema is mutually exclusive with --columns
    const test_schema_excl_columns = b.addSystemCommand(&.{
        "bash", "-c",
        \\msg=$(printf 'a,b\n1,2\n' | ./zig-out/bin/sql-pipe --schema --columns 2>&1 >/dev/null; echo "EXIT:$?")
        \\echo "$msg" | grep -q 'EXIT:1'
    });
    test_schema_excl_columns.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_schema_excl_columns.step);

    // Integration test 176j: --schema is mutually exclusive with --validate
    const test_schema_excl_validate = b.addSystemCommand(&.{
        "bash", "-c",
        \\msg=$(printf 'a,b\n1,2\n' | ./zig-out/bin/sql-pipe --schema --validate 2>&1 >/dev/null; echo "EXIT:$?")
        \\echo "$msg" | grep -q 'EXIT:1'
    });
    test_schema_excl_validate.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_schema_excl_validate.step);

    // Integration test 176k: --schema is mutually exclusive with --sample
    const test_schema_excl_sample = b.addSystemCommand(&.{
        "bash", "-c",
        \\msg=$(printf 'a,b\n1,2\n' | ./zig-out/bin/sql-pipe --schema --sample 2>&1 >/dev/null; echo "EXIT:$?")
        \\echo "$msg" | grep -q 'EXIT:1'
    });
    test_schema_excl_sample.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_schema_excl_sample.step);

    // Integration test 176l: --schema is mutually exclusive with --stats
    const test_schema_excl_stats = b.addSystemCommand(&.{
        "bash", "-c",
        \\msg=$(printf 'a,b\n1,2\n' | ./zig-out/bin/sql-pipe --schema --stats 2>&1 >/dev/null; echo "EXIT:$?")
        \\echo "$msg" | grep -q 'EXIT:1'
    });
    test_schema_excl_stats.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_schema_excl_stats.step);

    // Integration test 176m: --schema with a non-file positional arg exits 2 (tried as file)
    const test_schema_excl_query = b.addSystemCommand(&.{
        "bash", "-c",
        \\msg=$(printf 'a,b\n1,2\n' | ./zig-out/bin/sql-pipe --schema 'SELECT * FROM t' 2>&1 >/dev/null; echo "EXIT:$?")
        \\echo "$msg" | grep -q 'error: cannot open file' && echo "$msg" | grep -q 'EXIT:2'
    });
    test_schema_excl_query.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_schema_excl_query.step);

    // Integration test 176n: --schema is mutually exclusive with --output
    const test_schema_excl_output = b.addSystemCommand(&.{
        "bash", "-c",
        \\msg=$(printf 'a,b\n1,2\n' | ./zig-out/bin/sql-pipe --schema --output /tmp/x 2>&1 >/dev/null; echo "EXIT:$?")
        \\echo "$msg" | grep -q 'EXIT:1'
    });
    test_schema_excl_output.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_schema_excl_output.step);

    // Integration test 176o: --schema is mutually exclusive with -f/--file
    const test_schema_excl_file = b.addSystemCommand(&.{
        "bash", "-c",
        \\dir=$(mktemp -d)
        \\printf 'SELECT 1' > "$dir/q.sql"
        \\printf 'a,b\n1,2\n' > "$dir/d.csv"
        \\msg=$(./zig-out/bin/sql-pipe --schema -f "$dir/q.sql" "$dir/d.csv" 2>&1 >/dev/null; echo "EXIT:$?")
        \\rm -rf "$dir"
        \\echo "$msg" | grep -q 'EXIT:1'
    });
    test_schema_excl_file.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_schema_excl_file.step);

    // ─── Table output tests (--table / --no-table) ────────────────────────────

    // Integration test 156a: --table produces formatted table output
    const test_table_basic = b.addSystemCommand(&.{
        "bash", "-c",
        \\result=$(printf 'name,age\nAlice,30\nBob,25' | ./zig-out/bin/sql-pipe --table 'SELECT * FROM t')
        \\echo "$result" | grep -q '┌' && echo "$result" | grep -q '│ name' && echo "$result" | grep -q '│ Alice' && echo "$result" | grep -q '└'
    });
    test_table_basic.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_table_basic.step);

    // Integration test 156b: --no-table forces CSV output
    const test_no_table = b.addSystemCommand(&.{
        "bash", "-c",
        \\result=$(printf 'name,age\nAlice,30\nBob,25' | ./zig-out/bin/sql-pipe --no-table 'SELECT * FROM t')
        \\expected=$(printf 'Alice,30\nBob,25')
        \\[ "$result" = "$expected" ]
    });
    test_no_table.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_no_table.step);

    // Integration test 156c: --table with --json produces error
    const test_table_json_error = b.addSystemCommand(&.{
        "bash", "-c",
        \\msg=$(printf 'name,age\nAlice,30' | ./zig-out/bin/sql-pipe --table --json 'SELECT * FROM t' 2>&1; echo "EXIT:$?")
        \\echo "$msg" | grep -q '\-\-table requires CSV or TSV' && echo "$msg" | grep -q 'EXIT:1'
    });
    test_table_json_error.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_table_json_error.step);

    // Integration test 156d: piped output (no --table) stays CSV
    const test_piped_csv = b.addSystemCommand(&.{
        "bash", "-c",
        \\result=$(printf 'name,age\nAlice,30\nBob,25' | ./zig-out/bin/sql-pipe 'SELECT * FROM t')
        \\expected=$(printf 'Alice,30\nBob,25')
        \\[ "$result" = "$expected" ]
    });
    test_piped_csv.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_piped_csv.step);

    // Integration test 156e: table output right-aligns numeric columns
    const test_table_numeric_align = b.addSystemCommand(&.{
        "bash", "-c",
        \\result=$(printf 'name,score\nAlice,100\nBob,5' | ./zig-out/bin/sql-pipe --table 'SELECT * FROM t')
        \\echo "$result" | grep -q '100' && echo "$result" | grep -q '5' && echo "$result" | grep -q '│'
    });
    test_table_numeric_align.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_table_numeric_align.step);

    // Integration test 156f: empty result shows headers only
    const test_table_empty = b.addSystemCommand(&.{
        "bash", "-c",
        \\result=$(printf 'name,age\nAlice,30' | ./zig-out/bin/sql-pipe --table 'SELECT * FROM t WHERE age > 100')
        \\echo "$result" | grep -q '┌' && echo "$result" | grep -q '│ name' && echo "$result" | grep -q '└' && ! echo "$result" | grep -q 'Alice'
    });
    test_table_empty.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_table_empty.step);

    // Integration test 156g: --output writes CSV even with --table
    const test_table_output_file = b.addSystemCommand(&.{
        "bash", "-c",
        \\tmp=$(mktemp)
        \\printf 'name,age\nAlice,30\nBob,25' | ./zig-out/bin/sql-pipe --table --output "$tmp" 'SELECT * FROM t'
        \\result=$(cat "$tmp")
        \\rm -f "$tmp"
        \\expected=$(printf 'Alice,30\nBob,25')
        \\[ "$result" = "$expected" ]
    });
    test_table_output_file.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_table_output_file.step);

    // Integration test 157a: Auto-detect .json extension without -I flag
    const test_autodetect_json = b.addSystemCommand(&.{
        "bash", "-c",
        \\result=$(./zig-out/bin/sql-pipe tests/fixtures/products.json 'SELECT name FROM products WHERE CAST(stock AS INTEGER) > 0 ORDER BY name')
        \\expected=$(printf 'Doohickey\nGadget\nWidget')
        \\[ "$result" = "$expected" ]
    });
    test_autodetect_json.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_autodetect_json.step);

    // Integration test 157b: Auto-detect .ndjson extension without -I flag
    const test_autodetect_ndjson = b.addSystemCommand(&.{
        "bash", "-c",
        \\result=$(./zig-out/bin/sql-pipe tests/fixtures/events.ndjson 'SELECT event, COUNT(*) FROM events GROUP BY event ORDER BY event')
        \\expected=$(printf 'login,2\nlogout,1\npurchase,2')
        \\[ "$result" = "$expected" ]
    });
    test_autodetect_ndjson.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_autodetect_ndjson.step);

    // Integration test 157c: -I flag overrides file extension (JSON file forced to CSV)
    const test_override_json_to_csv = b.addSystemCommand(&.{
        "bash", "-c",
        \\tmp=/tmp/sqlpipe_test_override.json
        \\printf 'name,age\nAlice,30\nBob,25' > "$tmp"
        \\result=$(./zig-out/bin/sql-pipe -I csv "$tmp" 'SELECT name FROM sqlpipe_test_override ORDER BY name')
        \\rm -f "$tmp"
        \\expected=$(printf 'Alice\nBob')
        \\[ "$result" = "$expected" ]
    });
    test_override_json_to_csv.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_override_json_to_csv.step);

    // Integration test 157d: Ambiguous .txt extension defaults to CSV
    const test_ambiguous_txt_csv = b.addSystemCommand(&.{
        "bash", "-c",
        \\tmp=/tmp/sqlpipe_test_ambiguous.txt
        \\printf 'name,age\nAlice,30\nBob,25' > "$tmp"
        \\result=$(./zig-out/bin/sql-pipe "$tmp" 'SELECT name FROM sqlpipe_test_ambiguous ORDER BY name')
        \\rm -f "$tmp"
        \\expected=$(printf 'Alice\nBob')
        \\[ "$result" = "$expected" ]
    });
    test_ambiguous_txt_csv.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_ambiguous_txt_csv.step);

    // Integration test 157e: -I override with --input-format= syntax
    const test_override_long_flag = b.addSystemCommand(&.{
        "bash", "-c",
        \\tmp=/tmp/sqlpipe_test_long.json
        \\printf 'name,age\nAlice,30\nBob,25' > "$tmp"
        \\result=$(./zig-out/bin/sql-pipe --input-format=csv "$tmp" 'SELECT name FROM sqlpipe_test_long ORDER BY name')
        \\rm -f "$tmp"
        \\expected=$(printf 'Alice\nBob')
        \\[ "$result" = "$expected" ]
    });
    test_override_long_flag.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_override_long_flag.step);

    // Integration test 157f: -I override with -I= syntax
    const test_override_short_eq = b.addSystemCommand(&.{
        "bash", "-c",
        \\tmp=/tmp/sqlpipe_test_short.json
        \\printf 'name,age\nAlice,30\nBob,25' > "$tmp"
        \\result=$(./zig-out/bin/sql-pipe -I=csv "$tmp" 'SELECT name FROM sqlpipe_test_short ORDER BY name')
        \\rm -f "$tmp"
        \\expected=$(printf 'Alice\nBob')
        \\[ "$result" = "$expected" ]
    });
    test_override_short_eq.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_override_short_eq.step);

    // Integration test 157g: Ambiguous .txt extension with -I tsv override
    const test_ambiguous_txt_tsv = b.addSystemCommand(&.{
        "bash", "-c",
        \\tmp=/tmp/sqlpipe_test_tsv.txt
        \\printf 'name\tage\nAlice\t30\nBob\t25' > "$tmp"
        \\result=$(./zig-out/bin/sql-pipe -I tsv "$tmp" 'SELECT name FROM sqlpipe_test_tsv ORDER BY name')
        \\rm -f "$tmp"
        \\expected=$(printf 'Alice\nBob')
        \\[ "$result" = "$expected" ]
    });
    test_ambiguous_txt_tsv.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_ambiguous_txt_tsv.step);

    // Integration test 157h: Auto-detect .xml extension without -I flag
    const test_autodetect_xml = b.addSystemCommand(&.{
        "bash", "-c",
        \\result=$(./zig-out/bin/sql-pipe tests/fixtures/feed.xml --xml-root channel --xml-row item 'SELECT COUNT(*) FROM feed')
        \\[ "$result" = "3" ]
    });
    test_autodetect_xml.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_autodetect_xml.step);

    // ─── Markdown output integration tests ──────────────────────────────────────

    // Integration test 158a: Basic markdown output
    const test_markdown_basic = b.addSystemCommand(&.{
        "bash", "-c",
        \\result=$(printf 'name,age\nAlice,30\nBob,25\n' | ./zig-out/bin/sql-pipe -O markdown 'SELECT * FROM t ORDER BY name')
        \\echo "$result" | grep -Fq '| name' && echo "$result" | grep -Fq '| Alice' && echo "$result" | grep -q -e '---'
    });
    test_markdown_basic.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_markdown_basic.step);

    // Integration test 158b: -O md alias works
    const test_markdown_alias = b.addSystemCommand(&.{
        "bash", "-c",
        \\result=$(printf 'name,age\nAlice,30\n' | ./zig-out/bin/sql-pipe -O md 'SELECT * FROM t')
        \\echo "$result" | grep -Fq '| name' && echo "$result" | grep -Fq '| Alice'
    });
    test_markdown_alias.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_markdown_alias.step);

    // Integration test 158c: Numeric right-alignment (age column)
    const test_markdown_numeric = b.addSystemCommand(&.{
        "bash", "-c",
        \\result=$(printf 'name,age\nAlice,100\nBob,5\n' | ./zig-out/bin/sql-pipe -O markdown 'SELECT * FROM t ORDER BY name')
        \\echo "$result" | grep -Fq '100' && echo "$result" | grep -Fq '   5'
    });
    test_markdown_numeric.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_markdown_numeric.step);

    // Integration test 158d: NULL renders as empty cell (not the string "NULL")
    const test_markdown_null = b.addSystemCommand(&.{
        "bash", "-c",
        \\result=$(printf 'name,age\nAlice,30\nBob,\n' | ./zig-out/bin/sql-pipe -O markdown 'SELECT * FROM t ORDER BY name')
        \\echo "$result" | grep -Fq 'Bob' && echo "$result" | grep -qv 'NULL'
    });
    test_markdown_null.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_markdown_null.step);

    // Integration test 158e: Aggregation query produces valid markdown table
    const test_markdown_aggregate = b.addSystemCommand(&.{
        "bash", "-c",
        \\result=$(printf 'region,amount\nEast,100\nWest,200\nEast,150\n' | ./zig-out/bin/sql-pipe -O markdown 'SELECT region, SUM(amount) as total FROM t GROUP BY region ORDER BY region')
        \\echo "$result" | grep -Fq '| region' && echo "$result" | grep -Fq '| East' && echo "$result" | grep -Fq 'West' && echo "$result" | grep -q -e '---'
    });
    test_markdown_aggregate.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_markdown_aggregate.step);

    // Integration test 158f: Markdown with empty result set (headers + separator only)
    const test_markdown_empty = b.addSystemCommand(&.{
        "bash", "-c",
        \\result=$(printf 'name,age\nAlice,30\n' | ./zig-out/bin/sql-pipe -O markdown 'SELECT * FROM t WHERE age > 100')
        \\echo "$result" | grep -Fq '|' && echo "$result" | grep -q -e '---' && ! echo "$result" | grep -q 'Alice'
    });
    test_markdown_empty.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_markdown_empty.step);

    // ─── SQL INSERT output integration tests (issue #174) ─────────────────────

    // Integration test 174a: Basic SQL INSERT output
    const test_sql_basic = b.addSystemCommand(&.{
        "bash", "-c",
        \\result=$(printf 'name,age\nAlice,30\nBob,25\n' | ./zig-out/bin/sql-pipe -O sql 'SELECT * FROM t ORDER BY name')
        \\echo "$result" | grep -Fq 'INSERT INTO "t" ("name", "age") VALUES ('"'"'Alice'"'"', 30);' && \
        \\echo "$result" | grep -Fq 'INSERT INTO "t" ("name", "age") VALUES ('"'"'Bob'"'"', 25);'
    });
    test_sql_basic.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_sql_basic.step);

    // Integration test 174b: --sql-table flag with custom table name
    const test_sql_custom_table = b.addSystemCommand(&.{
        "bash", "-c",
        \\result=$(printf 'name\nAlice\n' | ./zig-out/bin/sql-pipe -O sql --sql-table users 'SELECT * FROM t')
        \\echo "$result" | grep -Fq 'INSERT INTO "users"'
    });
    test_sql_custom_table.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_sql_custom_table.step);

    // Integration test 174c: String escaping (single quotes doubled)
    const test_sql_escaping = b.addSystemCommand(&.{
        "bash", "-c",
        \\result=$(printf 'name\nO'"'"'Brien\nIt'"'"'s great\n' | ./zig-out/bin/sql-pipe -O sql 'SELECT * FROM t')
        \\echo "$result" | grep -Fq "VALUES ('O''Brien');" && \
        \\echo "$result" | grep -Fq "VALUES ('It''s great');"
    });
    test_sql_escaping.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_sql_escaping.step);

    // Integration test 174d: NULL values rendered as NULL (unquoted)
    const test_sql_null = b.addSystemCommand(&.{
        "bash", "-c",
        \\result=$(printf 'name,age\nAlice,30\nBob,\n' | ./zig-out/bin/sql-pipe -O sql 'SELECT * FROM t ORDER BY name')
        \\echo "$result" | grep -Fq 'NULL' && echo "$result" | grep -vq "'NULL'"
    });
    test_sql_null.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_sql_null.step);

    // Integration test 174e: Numeric values unquoted
    const test_sql_numeric = b.addSystemCommand(&.{
        "bash", "-c",
        \\result=$(printf 'n\n42\n-7\n' | ./zig-out/bin/sql-pipe -O sql 'SELECT * FROM t')
        \\echo "$result" | grep -Fq "(42);" && echo "$result" | grep -Fq "(-7);"
    });
    test_sql_numeric.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_sql_numeric.step);

    // Integration test 174f: Float value (non-trunc → with decimal, trunc → integer)
    const test_sql_float = b.addSystemCommand(&.{
        "bash", "-c",
        \\result=$(printf 'name,score\nAlice,3.14\nBob,30.0\n' | ./zig-out/bin/sql-pipe -O sql 'SELECT * FROM t ORDER BY name')
        \\echo "$result" | grep -Fq "3.14)" && echo "$result" | grep -Fq " 30);" && echo "$result" | grep -vq "30.0"
    });
    test_sql_float.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_sql_float.step);

    // Integration test 174g: Empty result set
    const test_sql_empty = b.addSystemCommand(&.{
        "bash", "-c",
        \\result=$(printf 'name,age\nAlice,30\n' | ./zig-out/bin/sql-pipe -O sql 'SELECT * FROM t WHERE age > 100')
        \\test -z "$result"
    });
    test_sql_empty.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_sql_empty.step);

    // Integration test 174h: Column name with special characters (quoted identifier)
    const test_sql_quoted_col = b.addSystemCommand(&.{
        "bash", "-c",
        \\result=$(printf 'a,b\n1,2\n' | ./zig-out/bin/sql-pipe -O sql 'SELECT 1 AS "my col", 2 AS "order"')
        \\echo "$result" | grep -Fq '"my col"' && echo "$result" | grep -Fq '"order"'
    });
    test_sql_quoted_col.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_sql_quoted_col.step);

    // Integration test 174i: Table name with spaces (output should quote it)
    const test_sql_quoted_table = b.addSystemCommand(&.{
        "bash", "-c",
        \\result=$(printf 'name\nAlice\n' | ./zig-out/bin/sql-pipe -O sql --sql-table 'my table' 'SELECT * FROM t')
        \\echo "$result" | grep -Fq '"my table"'
    });
    test_sql_quoted_table.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_sql_quoted_table.step);

    // ─── Fixture-based integration tests ─────────────────────────────────────
    // These tests use sample files committed in tests/fixtures/ to exercise
    // the binary end-to-end with realistic data across all supported formats.

    const fixture_test_step = b.step("fixture-test", "Run fixture-based integration tests");
    fixture_test_step.dependOn(b.getInstallStep());
    test_step.dependOn(fixture_test_step);

    // Fixture test 1: CSV file argument — basic query
    const fixture_csv_basic = b.addSystemCommand(&.{
        "bash", "-c",
        \\result=$(./zig-out/bin/sql-pipe tests/fixtures/orders.csv 'SELECT product, SUM(amount) FROM orders GROUP BY product ORDER BY product')
        \\expected=$(printf 'Doohickey,200.0\nGadget,125.5\nThingamajig,300.0\nWidget,345.25')
        \\[ "$result" = "$expected" ]
    });
    fixture_test_step.dependOn(&fixture_csv_basic.step);

    // Fixture test 2: CSV file argument — type inference (amount is REAL, date is DATE)
    const fixture_csv_types = b.addSystemCommand(&.{
        "bash", "-c",
        \\result=$(./zig-out/bin/sql-pipe tests/fixtures/orders.csv 'SELECT COUNT(*), SUM(amount) FROM orders WHERE amount > 100')
        \\[ "$result" = "4,770.0" ]
    });
    fixture_test_step.dependOn(&fixture_csv_types.step);

    // Fixture test 3: CSV file argument — date column works with SQLite date functions
    const fixture_csv_dates = b.addSystemCommand(&.{
        "bash", "-c",
        \\result=$(./zig-out/bin/sql-pipe tests/fixtures/orders.csv 'SELECT strftime("%Y", date) AS year, SUM(amount) FROM orders GROUP BY year ORDER BY year')
        \\expected=$(printf '2024,970.75')
        \\[ "$result" = "$expected" ]
    });
    fixture_test_step.dependOn(&fixture_csv_dates.step);

    // Fixture test 4: Multi-file CSV join (orders + customers)
    const fixture_csv_join = b.addSystemCommand(&.{
        "bash", "-c",
        \\result=$(./zig-out/bin/sql-pipe tests/fixtures/orders.csv tests/fixtures/customers.csv \
        \\    'SELECT c.name, c.region, SUM(o.amount) as total FROM orders o JOIN customers c ON o.customer_id = c.id GROUP BY c.name ORDER BY total DESC')
        \\expected=$(printf 'Alice,East,395.0\nBob,West,380.5\nCarol,East,195.25')
        \\[ "$result" = "$expected" ]
    });
    fixture_test_step.dependOn(&fixture_csv_join.step);

    // Fixture test 5: CSV file via stdin (piped)
    const fixture_csv_stdin = b.addSystemCommand(&.{
        "bash", "-c",
        \\result=$(cat tests/fixtures/orders.csv | ./zig-out/bin/sql-pipe 'SELECT DISTINCT product FROM t ORDER BY product')
        \\expected=$(printf 'Doohickey\nGadget\nThingamajig\nWidget')
        \\[ "$result" = "$expected" ]
    });
    fixture_test_step.dependOn(&fixture_csv_stdin.step);

    // Fixture test 6: JSON file argument — auto-detected from .json extension
    const fixture_json_file = b.addSystemCommand(&.{
        "bash", "-c",
        \\result=$(./zig-out/bin/sql-pipe tests/fixtures/products.json 'SELECT name, price FROM products ORDER BY CAST(price AS REAL) DESC')
        \\expected=$(printf 'Thingamajig,60.0\nDoohickey,50.0\nGadget,40.25\nWidget,25.0')
        \\[ "$result" = "$expected" ]
    });
    fixture_test_step.dependOn(&fixture_json_file.step);

    // Fixture test 7: JSON file — filter and aggregate
    const fixture_json_filter = b.addSystemCommand(&.{
        "bash", "-c",
        \\result=$(./zig-out/bin/sql-pipe tests/fixtures/products.json 'SELECT category, COUNT(*) FROM products GROUP BY category ORDER BY category')
        \\expected=$(printf 'electronics,2\nhardware,2')
        \\[ "$result" = "$expected" ]
    });
    fixture_test_step.dependOn(&fixture_json_filter.step);

    // Fixture test 8: JSON file via stdin
    const fixture_json_stdin = b.addSystemCommand(&.{
        "bash", "-c",
        \\result=$(cat tests/fixtures/products.json | ./zig-out/bin/sql-pipe -I json 'SELECT name FROM t WHERE CAST(stock AS INTEGER) > 0 ORDER BY name')
        \\expected=$(printf 'Doohickey\nGadget\nWidget')
        \\[ "$result" = "$expected" ]
    });
    fixture_test_step.dependOn(&fixture_json_stdin.step);

    // Fixture test 9: NDJSON file argument — auto-detected from .ndjson extension
    const fixture_ndjson_file = b.addSystemCommand(&.{
        "bash", "-c",
        \\result=$(./zig-out/bin/sql-pipe tests/fixtures/events.ndjson 'SELECT event, COUNT(*) FROM events GROUP BY event ORDER BY event')
        \\expected=$(printf 'login,2\nlogout,1\npurchase,2')
        \\[ "$result" = "$expected" ]
    });
    fixture_test_step.dependOn(&fixture_ndjson_file.step);

    // Fixture test 10: NDJSON file — user activity summary
    const fixture_ndjson_user = b.addSystemCommand(&.{
        "bash", "-c",
        \\result=$(./zig-out/bin/sql-pipe tests/fixtures/events.ndjson 'SELECT user, COUNT(*) as n FROM events GROUP BY user ORDER BY n DESC, user')
        \\expected=$(printf 'alice,3\nbob,1\ncarol,1')
        \\[ "$result" = "$expected" ]
    });
    fixture_test_step.dependOn(&fixture_ndjson_user.step);

    // Fixture test 11: XML file argument — auto-detected from .xml extension, with --xml-root/--xml-row
    const fixture_xml_file = b.addSystemCommand(&.{
        "bash", "-c",
        \\result=$(./zig-out/bin/sql-pipe tests/fixtures/feed.xml -I xml --xml-root channel --xml-row item 'SELECT author, title FROM feed ORDER BY author')
        \\expected=$(printf 'Alice,First Post\nBob,Second Post\nCarol,Third Post')
        \\[ "$result" = "$expected" ]
    });
    fixture_test_step.dependOn(&fixture_xml_file.step);

    // Fixture test 12: XML file — aggregate views
    const fixture_xml_aggregate = b.addSystemCommand(&.{
        "bash", "-c",
        \\result=$(./zig-out/bin/sql-pipe tests/fixtures/feed.xml -I xml --xml-root channel --xml-row item 'SELECT SUM(CAST(views AS INTEGER)) FROM feed')
        \\[ "$result" = "430" ]
    });
    fixture_test_step.dependOn(&fixture_xml_aggregate.step);

    // Fixture test 13: XML file via stdin
    const fixture_xml_stdin = b.addSystemCommand(&.{
        "bash", "-c",
        \\result=$(cat tests/fixtures/feed.xml | ./zig-out/bin/sql-pipe -I xml --xml-root channel --xml-row item 'SELECT title FROM t WHERE CAST(views AS INTEGER) > 100 ORDER BY title')
        \\expected=$(printf 'First Post\nThird Post')
        \\[ "$result" = "$expected" ]
    });
    fixture_test_step.dependOn(&fixture_xml_stdin.step);

    // Fixture test 13: Mixed format — CSV file + JSON file join (via shared column)
    // orders.csv has "product" column, products.json has "name" column
    const fixture_mixed_join = b.addSystemCommand(&.{
        "bash", "-c",
        \\result=$(./zig-out/bin/sql-pipe tests/fixtures/orders.csv tests/fixtures/products.json \
        \\    'SELECT o.product, p.category, SUM(o.amount) FROM orders o JOIN products p ON o.product = p.name GROUP BY o.product ORDER BY o.product' 2>/dev/null)
        \\expected=$(printf 'Doohickey,hardware,200.0\nGadget,electronics,125.5\nThingamajig,electronics,300.0\nWidget,hardware,345.25')
        \\[ "$result" = "$expected" ]
    });
    fixture_test_step.dependOn(&fixture_mixed_join.step);

    // Fixture test 14: CSV file + NDJSON file mix (auto-detected from extensions)
    const fixture_csv_ndjson_mix = b.addSystemCommand(&.{
        "bash", "-c",
        \\result=$(./zig-out/bin/sql-pipe tests/fixtures/events.ndjson tests/fixtures/customers.csv \
        \\    'SELECT c.name, e.event FROM events e JOIN customers c ON LOWER(e.user) = LOWER(c.name) ORDER BY c.name, e.event')
        \\expected=$(printf 'Alice,login\nAlice,logout\nAlice,purchase\nBob,purchase\nCarol,login')
        \\[ "$result" = "$expected" ]
    });
    fixture_test_step.dependOn(&fixture_csv_ndjson_mix.step);

    // Fixture test 15: --columns with fixture file (via stdin)
    const fixture_columns = b.addSystemCommand(&.{
        "bash", "-c",
        \\result=$(cat tests/fixtures/orders.csv | ./zig-out/bin/sql-pipe --columns)
        \\expected=$(printf 'id\ncustomer_id\nproduct\namount\ndate')
        \\[ "$result" = "$expected" ]
    });
    fixture_test_step.dependOn(&fixture_columns.step);

    // Fixture test 16: --validate with fixture file (via stdin)
    const fixture_validate = b.addSystemCommand(&.{
        "bash", "-c",
        \\result=$(cat tests/fixtures/orders.csv | ./zig-out/bin/sql-pipe --validate)
        \\echo "$result" | grep -q 'OK: 7 rows, 5 columns'
    });
    fixture_test_step.dependOn(&fixture_validate.step);

    // Fixture test 17: --sample with fixture file (via stdin)
    const fixture_sample = b.addSystemCommand(&.{
        "bash", "-c",
        \\result=$(cat tests/fixtures/orders.csv | ./zig-out/bin/sql-pipe --sample 2 2>/dev/null)
        \\expected=$(printf 'id,customer_id,product,amount,date\n1,1,Widget,150.00,2024-01-15\n2,2,Gadget,80.50,2024-02-20')
        \\[ "$result" = "$expected" ]
    });
    fixture_test_step.dependOn(&fixture_sample.step);

    // Fixture test 18: --output with fixture file
    const fixture_output = b.addSystemCommand(&.{
        "bash", "-c",
        \\tmp=$(mktemp)
        \\./zig-out/bin/sql-pipe tests/fixtures/orders.csv --output "$tmp" 'SELECT COUNT(*) FROM orders'
        \\result=$(cat "$tmp")
        \\rm -f "$tmp"
        \\[ "$result" = "7" ]
    });
    fixture_test_step.dependOn(&fixture_output.step);

    // Fixture test 19: JSON output from CSV fixture
    const fixture_json_output = b.addSystemCommand(&.{
        "bash", "-c",
        \\result=$(./zig-out/bin/sql-pipe tests/fixtures/customers.csv --json 'SELECT name, region FROM customers ORDER BY name')
        \\expected='[{"name":"Alice","region":"East"},{"name":"Bob","region":"West"},{"name":"Carol","region":"East"}]'
        \\[ "$result" = "$expected" ]
    });
    fixture_test_step.dependOn(&fixture_json_output.step);

    // Fixture test 20: --header with fixture file
    const fixture_header = b.addSystemCommand(&.{
        "bash", "-c",
        \\result=$(./zig-out/bin/sql-pipe tests/fixtures/customers.csv --header 'SELECT name FROM customers ORDER BY name')
        \\expected=$(printf 'name\nAlice\nBob\nCarol')
        \\[ "$result" = "$expected" ]
    });
    fixture_test_step.dependOn(&fixture_header.step);

    // Fixture test 21: --columns with file argument
    const fixture_columns_file = b.addSystemCommand(&.{
        "bash", "-c",
        \\result=$(./zig-out/bin/sql-pipe tests/fixtures/orders.csv --columns)
        \\expected=$(printf 'id\ncustomer_id\nproduct\namount\ndate')
        \\[ "$result" = "$expected" ]
    });
    fixture_test_step.dependOn(&fixture_columns_file.step);

    // Fixture test 22: --validate with file argument
    const fixture_validate_file = b.addSystemCommand(&.{
        "bash", "-c",
        \\result=$(./zig-out/bin/sql-pipe tests/fixtures/orders.csv --validate)
        \\echo "$result" | grep -q 'OK: 7 rows, 5 columns'
    });
    fixture_test_step.dependOn(&fixture_validate_file.step);

    // Fixture test 23: --sample with file argument
    const fixture_sample_file = b.addSystemCommand(&.{
        "bash", "-c",
        \\result=$(./zig-out/bin/sql-pipe tests/fixtures/orders.csv --sample 2 2>/dev/null)
        \\expected=$(printf 'id,customer_id,product,amount,date\n1,1,Widget,150.00,2024-01-15\n2,2,Gadget,80.50,2024-02-20')
        \\[ "$result" = "$expected" ]
    });
    fixture_test_step.dependOn(&fixture_sample_file.step);

    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/csv.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);
    const unit_test_step = b.step("unit-test", "Run CSV unit tests");
    unit_test_step.dependOn(&run_unit_tests.step);

    // Unit tests for the XML parser (src/xml.zig)
    const xml_unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/xml.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    xml_unit_tests.root_module.addImport("c", translate_c.createModule());
    if (bundle_sqlite) {
        xml_unit_tests.root_module.addIncludePath(b.path("lib"));
        xml_unit_tests.root_module.addCSourceFile(.{
            .file = b.path("lib/sqlite3.c"),
            .flags = &.{"-DSQLITE_OMIT_LOAD_EXTENSION=1"},
        });
    } else {
        xml_unit_tests.root_module.linkSystemLibrary("sqlite3", .{});
    }
    const run_xml_unit_tests = b.addRunArtifact(xml_unit_tests);
    test_step.dependOn(&run_xml_unit_tests.step);
    unit_test_step.dependOn(&run_xml_unit_tests.step);

    // Unit tests for the CSV loader (src/loader.zig) — isDate, isDateTime, inferTypes, normalize helpers
    const loader_unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/loader.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    loader_unit_tests.root_module.addImport("c", translate_c.createModule());
    if (bundle_sqlite) {
        loader_unit_tests.root_module.addIncludePath(b.path("lib"));
        loader_unit_tests.root_module.addCSourceFile(.{
            .file = b.path("lib/sqlite3.c"),
            .flags = &.{"-DSQLITE_OMIT_LOAD_EXTENSION=1"},
        });
    } else {
        loader_unit_tests.root_module.linkSystemLibrary("sqlite3", .{});
    }
    const run_loader_unit_tests = b.addRunArtifact(loader_unit_tests);
    unit_test_step.dependOn(&run_loader_unit_tests.step);

    // ─── --stats / --profile integration tests ──────────────────────────

    // Integration test: --stats on basic CSV with mixed types
    const test_stats_basic = b.addSystemCommand(&.{
        "bash", "-c",
        \\result=$(printf 'id,amount,region\n1,100,east\n2,200,west\n3,300,north\n' | ./zig-out/bin/sql-pipe --stats 2>/dev/null)
        \\echo "$result" | grep -q 'id' && echo "$result" | grep -q 'INTEGER' && echo "$result" | grep -q 'region.*TEXT'
    });
    test_stats_basic.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_stats_basic.step);

    // Integration test: --profile alias works
    const test_stats_alias = b.addSystemCommand(&.{
        "bash", "-c",
        \\result=$(printf 'name,score\nAlice,95.5\nBob,87.3\n' | ./zig-out/bin/sql-pipe --profile 2>/dev/null)
        \\echo "$result" | grep -q 'Alice' && echo "$result" | grep -q '91.4'
    });
    test_stats_alias.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_stats_alias.step);

    // Integration test: --stats cannot be combined with --columns, --validate, --sample, query, --output
    const test_stats_with_columns = b.addSystemCommand(&.{
        "bash", "-c",
        \\msg=$(printf 'a,b\n1,2\n' | ./zig-out/bin/sql-pipe --stats --columns 2>&1 >/dev/null; echo "EXIT:$?")
        \\echo "$msg" | grep -q 'error: --stats is incompatible' && echo "$msg" | grep -q 'EXIT:1'
    });
    test_stats_with_columns.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_stats_with_columns.step);

    // Integration test: --stats cannot be combined with --validate
    const test_stats_with_validate = b.addSystemCommand(&.{
        "bash", "-c",
        \\msg=$(printf 'a,b\n1,2\n' | ./zig-out/bin/sql-pipe --stats --validate 2>&1 >/dev/null; echo "EXIT:$?")
        \\echo "$msg" | grep -q 'error: --stats is incompatible' && echo "$msg" | grep -q 'EXIT:1'
    });
    test_stats_with_validate.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_stats_with_validate.step);

    // Integration test: --stats cannot be combined with --sample
    const test_stats_with_sample = b.addSystemCommand(&.{
        "bash", "-c",
        \\msg=$(printf 'a,b\n1,2\n' | ./zig-out/bin/sql-pipe --stats --sample 2>&1 >/dev/null; echo "EXIT:$?")
        \\echo "$msg" | grep -q 'error: --stats is incompatible' && echo "$msg" | grep -q 'EXIT:1'
    });
    test_stats_with_sample.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_stats_with_sample.step);

    // Integration test: --stats cannot be combined with query argument (-f)
    const test_stats_with_query = b.addSystemCommand(&.{
        "bash", "-c",
        \\msg=$(printf 'a,b\n1,2\n' | ./zig-out/bin/sql-pipe --stats -f /dev/null 2>&1 >/dev/null; echo "EXIT:$?")
        \\echo "$msg" | grep -q 'error: --stats is incompatible' && echo "$msg" | grep -q 'EXIT:1'
    });
    test_stats_with_query.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_stats_with_query.step);

    // Integration test: --stats cannot be combined with --output
    const test_stats_with_output = b.addSystemCommand(&.{
        "bash", "-c",
        \\msg=$(printf 'a,b\n1,2\n' | ./zig-out/bin/sql-pipe --stats --output /tmp/sp_test_out.csv 2>&1 >/dev/null; echo "EXIT:$?")
        \\echo "$msg" | grep -q 'error: --stats is incompatible' && echo "$msg" | grep -q 'EXIT:1'
    });
    test_stats_with_output.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_stats_with_output.step);

    // Integration test: --stats on TSV input
    const test_stats_tsv = b.addSystemCommand(&.{
        "bash", "-c",
        \\result=$(printf 'name\tage\nAlice\t30\nBob\t25\n' | ./zig-out/bin/sql-pipe -I tsv --stats 2>/dev/null)
        \\echo "$result" | grep -q 'Alice' && echo "$result" | grep -q '25'
    });
    test_stats_tsv.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_stats_tsv.step);

    // Integration test: --stats on JSON input (all TEXT columns)
    const test_stats_json = b.addSystemCommand(&.{
        "bash", "-c",
        \\result=$(printf '[{"id":1,"val":10},{"id":2,"val":20}]' | ./zig-out/bin/sql-pipe -I json --stats 2>/dev/null)
        \\echo "$result" | grep -q 'TEXT' && echo "$result" | grep -q '10'
    });
    test_stats_json.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_stats_json.step);

    // Integration test: --stats with REAL columns
    const test_stats_real = b.addSystemCommand(&.{
        "bash", "-c",
        \\result=$(printf 'item,price\nA,9.99\nB,3.00\nC,12.50\n' | ./zig-out/bin/sql-pipe --stats 2>/dev/null)
        \\echo "$result" | grep -q 'REAL' && echo "$result" | grep -q '8.49666'
    });
    test_stats_real.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_stats_real.step);

    // Integration test: --stats with no-type-inference (all TEXT)
    const test_stats_no_infer = b.addSystemCommand(&.{
        "bash", "-c",
        \\result=$(printf 'id,val\n1,10\n2,20\n' | ./zig-out/bin/sql-pipe --stats --no-type-inference 2>/dev/null)
        \\echo "$result" | grep -q 'TEXT' && echo "$result" | grep -qv 'INTEGER'
    });
    test_stats_no_infer.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_stats_no_infer.step);

    // Integration test: --stats with custom delimiter
    const test_stats_delimiter = b.addSystemCommand(&.{
        "bash", "-c",
        \\result=$(printf 'a|b\n1|2\n3|4\n' | ./zig-out/bin/sql-pipe --stats -d '|' 2>/dev/null)
        \\echo "$result" | grep -q 'INTEGER' && echo "$result" | grep -q '2.0'
    });
    test_stats_delimiter.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_stats_delimiter.step);

    // ─── --null-value integration tests (issue #170) ─────────────────────────

    // Integration test 170a: CSV output respects --null-value 'N/A'
    const test_null_value_csv = b.addSystemCommand(&.{
        "bash", "-c",
        \\result=$(printf 'name,score\nAlice,30\nBob,\nCarol,35\n' \
        \\    | ./zig-out/bin/sql-pipe --null-value 'N/A' 'SELECT name, score FROM t ORDER BY name')
        \\expected=$(printf 'Alice,30\nBob,N/A\nCarol,35')
        \\[ "$result" = "$expected" ]
    });
    test_null_value_csv.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_null_value_csv.step);

    // Integration test 170b: CSV output respects --null-value '' (explicit empty string)
    const test_null_value_csv_empty = b.addSystemCommand(&.{
        "bash", "-c",
        \\result=$(printf 'name,score\nAlice,30\nBob,\n' \
        \\    | ./zig-out/bin/sql-pipe --null-value '' 'SELECT name, score FROM t ORDER BY name')
        \\expected=$(printf 'Alice,30\nBob,')
        \\[ "$result" = "$expected" ]
    });
    test_null_value_csv_empty.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_null_value_csv_empty.step);

    // Integration test 170c: CSV default unchanged when no flag (still "NULL")
    const test_null_value_csv_default = b.addSystemCommand(&.{
        "bash", "-c",
        \\result=$(printf 'name,score\nAlice,30\nBob,\n' \
        \\    | ./zig-out/bin/sql-pipe 'SELECT name, score FROM t ORDER BY name')
        \\expected=$(printf 'Alice,30\nBob,NULL')
        \\[ "$result" = "$expected" ]
    });
    test_null_value_csv_default.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_null_value_csv_default.step);

    // Integration test 170d: TSV output respects --null-value '-'
    const test_null_value_tsv = b.addSystemCommand(&.{
        "bash", "-c",
        \\result=$(printf 'name,score\nAlice,30\nBob,\n' \
        \\    | ./zig-out/bin/sql-pipe -O tsv --null-value '-' 'SELECT name, score FROM t ORDER BY name')
        \\expected=$(printf 'Alice\t30\nBob\t-')
        \\[ "$result" = "$expected" ]
    });
    test_null_value_tsv.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_null_value_tsv.step);

    // Integration test 170e: JSON ignores --null-value (still outputs JSON null)
    const test_null_value_json_ignored = b.addSystemCommand(&.{
        "bash", "-c",
        \\result=$(printf 'name,score\nAlice,30\nBob,\n' \
        \\    | ./zig-out/bin/sql-pipe --json --null-value 'N/A' 'SELECT name, score FROM t ORDER BY name')
        \\expected=$(printf '[{"name":"Alice","score":30},{"name":"Bob","score":null}]')
        \\[ "$result" = "$expected" ]
    });
    test_null_value_json_ignored.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_null_value_json_ignored.step);

    // Integration test 170f: NDJSON ignores --null-value (still outputs JSON null)
    const test_null_value_ndjson_ignored = b.addSystemCommand(&.{
        "bash", "-c",
        \\result=$(printf 'name,score\nAlice,30\nBob,\n' \
        \\    | ./zig-out/bin/sql-pipe -O ndjson --null-value 'N/A' 'SELECT name, score FROM t ORDER BY name')
        \\expected=$(printf '{"name":"Alice","score":30}\n{"name":"Bob","score":null}')
        \\[ "$result" = "$expected" ]
    });
    test_null_value_ndjson_ignored.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_null_value_ndjson_ignored.step);

    // Integration test 170g: XML output respects --null-value 'N/A'
    const test_null_value_xml = b.addSystemCommand(&.{
        "bash", "-c",
        \\result=$(printf 'name,score\nAlice,30\nBob,\n' \
        \\    | ./zig-out/bin/sql-pipe -O xml --null-value 'N/A' 'SELECT name, score FROM t ORDER BY name')
        \\echo "$result" | grep -q '<score>N/A</score>'
    });
    test_null_value_xml.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_null_value_xml.step);

    // Integration test 170h: XML default null renders empty element
    const test_null_value_xml_default = b.addSystemCommand(&.{
        "bash", "-c",
        \\result=$(printf 'name,score\nAlice,30\nBob,\n' \
        \\    | ./zig-out/bin/sql-pipe -O xml 'SELECT name, score FROM t ORDER BY name')
        \\echo "$result" | grep -q '<score></score>'
    });
    test_null_value_xml_default.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_null_value_xml_default.step);

    // Integration test 170i: --null-value with --help includes flag in output
    const test_null_value_help = b.addSystemCommand(&.{
        "bash", "-c",
        \\./zig-out/bin/sql-pipe --help 2>&1 >/dev/null | grep -q -e '--null-value'
    });
    test_null_value_help.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_null_value_help.step);

    // Integration test 170j: --null-value without value exits 1
    const test_null_value_missing = b.addSystemCommand(&.{
        "bash", "-c",
        \\./zig-out/bin/sql-pipe --null-value 2>&1 >/dev/null; test $? -eq 1
    });
    test_null_value_missing.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_null_value_missing.step);

    // Integration test 170k: table output respects --null-value
    const test_null_value_table = b.addSystemCommand(&.{
        "bash", "-c",
        \\result=$(printf 'name,score\nAlice,30\nBob,\n' | ./zig-out/bin/sql-pipe --table --null-value 'N/A' 'SELECT name, score FROM t ORDER BY name')
        \\echo "$result" | grep -q 'N/A'
    });
    test_null_value_table.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_null_value_table.step);

    // Integration test 170l: markdown output respects --null-value (non-numeric column)
    const test_null_value_markdown = b.addSystemCommand(&.{
        "bash", "-c",
        \\result=$(printf 'name,note\nAlice,good\nBob,\n' | ./zig-out/bin/sql-pipe -O markdown --null-value 'MISSING' 'SELECT name, note FROM t ORDER BY name')
        \\echo "$result" | grep -q 'MISSING'
    });
    test_null_value_markdown.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_null_value_markdown.step);

    // ─── --explain integration tests ─────────────────────────────────────

    // Integration test: --explain basic — prints plan to stderr, results to stdout, exit 0
    const test_explain_basic = b.addSystemCommand(&.{
        "bash", "-c",
        \\data='a,b\n1,2\n3,4\n'
        \\stderr=$(printf "$data" | ./zig-out/bin/sql-pipe --explain 'SELECT * FROM t' 2>&1 >/dev/null)
        \\echo "$stderr" | grep -q 'QUERY PLAN:' || exit 1
        \\stdout=$(printf "$data" | ./zig-out/bin/sql-pipe --explain 'SELECT * FROM t' 2>/dev/null)
        \\[ "$stdout" = "$(printf '1,2\n3,4')" ] || exit 1
    });
    test_explain_basic.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_explain_basic.step);

    // Integration test: --explain stdout not contaminated with "QUERY PLAN:"
    const test_explain_stdout_clean = b.addSystemCommand(&.{
        "bash", "-c",
        \\result=$(printf 'a,b\n1,2\n' | ./zig-out/bin/sql-pipe --explain 'SELECT * FROM t' 2>/dev/null | grep -c 'QUERY' || true)
        \\[ "$result" = "0" ]
    });
    test_explain_stdout_clean.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_explain_stdout_clean.step);

    // Integration test: --explain exit code 0 on success
    const test_explain_exit_0 = b.addSystemCommand(&.{
        "bash", "-c",
        \\printf 'a,b\n1,2\n' | ./zig-out/bin/sql-pipe --explain 'SELECT * FROM t' >/dev/null 2>&1
        \\[ $? -eq 0 ]
    });
    test_explain_exit_0.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_explain_exit_0.step);

    // Integration test: --explain + --columns → error exit 1
    const test_explain_with_columns = b.addSystemCommand(&.{
        "bash", "-c",
        \\msg=$(printf 'a,b\n1,2\n' | ./zig-out/bin/sql-pipe --explain --columns 2>&1 >/dev/null; echo "EXIT:$?")
        \\echo "$msg" | grep -q 'error: --explain cannot be combined' && echo "$msg" | grep -q 'EXIT:1'
    });
    test_explain_with_columns.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_explain_with_columns.step);

    // Integration test: --explain + --validate → error exit 1
    const test_explain_with_validate = b.addSystemCommand(&.{
        "bash", "-c",
        \\msg=$(printf 'a,b\n1,2\n' | ./zig-out/bin/sql-pipe --explain --validate 2>&1 >/dev/null; echo "EXIT:$?")
        \\echo "$msg" | grep -q 'error: --explain cannot be combined' && echo "$msg" | grep -q 'EXIT:1'
    });
    test_explain_with_validate.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_explain_with_validate.step);

    // Integration test: --explain + --sample → error exit 1
    const test_explain_with_sample = b.addSystemCommand(&.{
        "bash", "-c",
        \\msg=$(printf 'a,b\n1,2\n' | ./zig-out/bin/sql-pipe --explain --sample 2>&1 >/dev/null; echo "EXIT:$?")
        \\echo "$msg" | grep -q 'error: --explain cannot be combined' && echo "$msg" | grep -q 'EXIT:1'
    });
    test_explain_with_sample.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_explain_with_sample.step);

    // Integration test: --explain + --stats → error exit 1
    const test_explain_with_stats = b.addSystemCommand(&.{
        "bash", "-c",
        \\msg=$(printf 'a,b\n1,2\n' | ./zig-out/bin/sql-pipe --explain --stats 2>&1 >/dev/null; echo "EXIT:$?")
        \\echo "$msg" | grep -q 'error: --explain cannot be combined' && echo "$msg" | grep -q 'EXIT:1'
    });
    test_explain_with_stats.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_explain_with_stats.step);

    // Integration test: --explain + --output → error exit 1
    const test_explain_with_output = b.addSystemCommand(&.{
        "bash", "-c",
        \\msg=$(printf 'a,b\n1,2\n' | ./zig-out/bin/sql-pipe --explain --output /tmp/sp_test_out.csv 2>&1 >/dev/null; echo "EXIT:$?")
        \\echo "$msg" | grep -q 'error: --explain cannot be combined' && echo "$msg" | grep -q 'EXIT:1'
    });
    test_explain_with_output.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_explain_with_output.step);

    // Integration test: --help contains --explain
    const test_explain_help = b.addSystemCommand(&.{
        "bash", "-c",
        \\./zig-out/bin/sql-pipe --help 2>&1 >/dev/null | grep -q -- '--explain'
    });
    test_explain_help.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_explain_help.step);

    // Integration test: --explain with nonexistent table → exit 3
    const test_explain_nonexistent = b.addSystemCommand(&.{
        "bash", "-c",
        \\msg=$(printf 'a,b\n1,2\n' | ./zig-out/bin/sql-pipe --explain 'SELECT * FROM nonexistent' 2>&1 >/dev/null; echo "EXIT:$?")
        \\echo "$msg" | grep -q 'error: no such table' && echo "$msg" | grep -q 'EXIT:3'
    });
    test_explain_nonexistent.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_explain_nonexistent.step);

    // Integration test: --explain with -f/--file query
    const test_explain_query_file = b.addSystemCommand(&.{
        "bash", "-c",
        \\tmp=$(mktemp)
        \\printf 'SELECT * FROM t' > "$tmp"
        \\result=$(printf 'x\n1\n2\n' | ./zig-out/bin/sql-pipe -f "$tmp" --explain 2>/dev/null)
        \\rm -f "$tmp"
        \\[ "$result" = "$(printf '1\n2')" ]
    });
    test_explain_query_file.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_explain_query_file.step);

    // Integration test: --explain with empty stdin (< /dev/null) — no crash
    const test_explain_empty_stdin = b.addSystemCommand(&.{
        "bash", "-c",
        \\./zig-out/bin/sql-pipe --explain 'SELECT 1' < /dev/null >/dev/null 2>&1
        \\[ $? -eq 0 ]
    });
    test_explain_empty_stdin.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_explain_empty_stdin.step);
}
