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
    ) orelse "0.2.0";

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
        exe.addIncludePath(b.path("lib"));
        exe.addCSourceFile(.{
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
