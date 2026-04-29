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

    // Integration test 37: --columns combined with a query argument exits 1 with error
    const test_columns_with_query = b.addSystemCommand(&.{
        "bash", "-c",
        \\msg=$(printf 'a,b\n1,2\n' | ./zig-out/bin/sql-pipe --columns 'SELECT * FROM t' 2>&1 >/dev/null; echo "EXIT:$?")
        \\echo "$msg" | grep -q 'error: --columns cannot be combined with a query argument' && echo "$msg" | grep -q 'EXIT:1'
    });
    test_columns_with_query.step.dependOn(b.getInstallStep());
    test_step.dependOn(&test_columns_with_query.step);

    // Unit tests for the RFC 4180 CSV parser (src/csv.zig)
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
}
