const std = @import("std");
const zon = @import("build.zig.zon");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const codecs_str = b.option(
        []const u8,
        "codecs",
        "Compression codecs (default: all). Values: all, c-only, none, zig-only, or comma-separated list of: c-zstd,zstd,c-snappy,snappy,c-gzip,gzip,c-lz4,lz4,c-brotli,brotli",
    ) orelse "all";

    const codecs = parseCodecs(codecs_str);

    const build_options = b.addOptions();
    build_options.addOption(bool, "enable_zstd", codecs.zstd);
    build_options.addOption(bool, "enable_zig_zstd", codecs.zig_zstd);
    build_options.addOption(bool, "supports_zstd", codecs.zstd or codecs.zig_zstd);
    build_options.addOption(bool, "enable_snappy", codecs.snappy);
    build_options.addOption(bool, "enable_zig_snappy", codecs.zig_snappy);
    build_options.addOption(bool, "supports_snappy", codecs.snappy or codecs.zig_snappy);
    build_options.addOption(bool, "enable_gzip", codecs.gzip);
    build_options.addOption(bool, "enable_zig_gzip", codecs.zig_gzip);
    build_options.addOption(bool, "supports_gzip", codecs.gzip or codecs.zig_gzip);
    build_options.addOption(bool, "enable_lz4", codecs.lz4);
    build_options.addOption(bool, "enable_zig_lz4", codecs.zig_lz4);
    build_options.addOption(bool, "supports_lz4", codecs.lz4 or codecs.zig_lz4);
    build_options.addOption(bool, "enable_brotli", codecs.brotli);
    build_options.addOption(bool, "enable_zig_brotli", codecs.zig_brotli);
    build_options.addOption(bool, "supports_brotli", codecs.brotli or codecs.zig_brotli);
    build_options.addOption([]const u8, "version", zon.version);

    const deps = resolveDeps(b, codecs);

    // Create a module for the library
    const parquet_mod = b.addModule("parquet", .{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });
    parquet_mod.addImport("build_options", build_options.createModule());

    // Library artifact
    const lib = b.addLibrary(.{
        .name = "parquet",
        .root_module = parquet_mod,
    });

    configureCodecs(lib.root_module, deps, b);

    b.installArtifact(lib);

    // Unit tests
    const test_mod = b.addModule("parquet_test", .{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_mod.addImport("build_options", build_options.createModule());

    const lib_unit_tests = b.addTest(.{
        .root_module = test_mod,
    });

    configureCodecs(lib_unit_tests.root_module, deps, b);

    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);

    const check_test_files = b.addSystemCommand(&.{
        "sh", "-c",
        \\test -f ../test-files-arrow/basic/basic_types_plain_uncompressed.parquet || {
        \\  echo ""
        \\  echo "ERROR: Test files not found."
        \\  echo "Generate them first:  cd test-files-arrow && uv run python generate.py"
        \\  echo ""
        \\  exit 1
        \\}
    });
    run_lib_unit_tests.step.dependOn(&check_test_files.step);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);
}

// =========================================================================
// Codec configuration
// =========================================================================

const Codecs = struct {
    zstd: bool, // C libzstd (opt-in via c-only or explicit codec name)
    zig_zstd: bool, // pure Zig zstd
    snappy: bool, // C++ snappy (opt-in via c-only or explicit codec name)
    zig_snappy: bool, // pure Zig snappy
    gzip: bool, // C zlib (opt-in via c-only or explicit codec name)
    zig_gzip: bool, // pure Zig gzip
    lz4: bool, // C lz4 (opt-in via c-only or explicit codec name)
    zig_lz4: bool, // pure Zig lz4
    brotli: bool, // C brotli (opt-in via c-only or explicit codec name)
    zig_brotli: bool, // pure Zig brotli

    fn anyC(self: Codecs) bool {
        return self.zstd or self.snappy or self.gzip or self.lz4 or self.brotli;
    }
};

fn parseCodecs(str: []const u8) Codecs {
    if (std.mem.eql(u8, str, "all")) return .{ .zstd = true, .zig_zstd = true, .snappy = true, .zig_snappy = true, .gzip = true, .zig_gzip = true, .lz4 = true, .zig_lz4 = true, .brotli = true, .zig_brotli = true };
    if (std.mem.eql(u8, str, "c-only")) return .{ .zstd = true, .zig_zstd = false, .snappy = true, .zig_snappy = false, .gzip = true, .zig_gzip = false, .lz4 = true, .zig_lz4 = false, .brotli = true, .zig_brotli = false };
    if (std.mem.eql(u8, str, "none")) return .{ .zstd = false, .zig_zstd = false, .snappy = false, .zig_snappy = false, .gzip = false, .zig_gzip = false, .lz4 = false, .zig_lz4 = false, .brotli = false, .zig_brotli = false };
    if (std.mem.eql(u8, str, "zig-only")) return .{ .zstd = false, .zig_zstd = true, .snappy = false, .zig_snappy = true, .gzip = false, .zig_gzip = true, .lz4 = false, .zig_lz4 = true, .brotli = false, .zig_brotli = true };
    return .{
        .zstd = containsCodec(str, "c-zstd"),
        .zig_zstd = containsCodec(str, "zstd"),
        .snappy = containsCodec(str, "c-snappy"),
        .zig_snappy = containsCodec(str, "snappy"),
        .gzip = containsCodec(str, "c-gzip"),
        .zig_gzip = containsCodec(str, "gzip"),
        .lz4 = containsCodec(str, "c-lz4"),
        .zig_lz4 = containsCodec(str, "lz4"),
        .brotli = containsCodec(str, "c-brotli"),
        .zig_brotli = containsCodec(str, "brotli"),
    };
}

fn containsCodec(csv: []const u8, name: []const u8) bool {
    var iter = std.mem.splitScalar(u8, csv, ',');
    while (iter.next()) |token| {
        const trimmed = std.mem.trim(u8, token, " ");
        if (std.mem.eql(u8, trimmed, name)) return true;
    }
    return false;
}

const Deps = struct {
    lz4: ?*std.Build.Dependency,
    brotli: ?*std.Build.Dependency,
    snappy: ?*std.Build.Dependency,
    zstd: ?*std.Build.Dependency,
    zlib: ?*std.Build.Dependency,
    codecs: Codecs,
};

fn resolveDeps(b: *std.Build, codecs: Codecs) Deps {
    return .{
        .lz4 = if (codecs.lz4) b.dependency("lz4", .{}) else null,
        .brotli = if (codecs.brotli) b.dependency("brotli", .{}) else null,
        .snappy = if (codecs.snappy) b.dependency("snappy", .{}) else null,
        .zstd = if (codecs.zstd) b.dependency("zstd", .{}) else null,
        .zlib = if (codecs.gzip) b.dependency("zlib", .{}) else null,
        .codecs = codecs,
    };
}

fn configureCodecs(module: *std.Build.Module, deps: Deps, b: *std.Build) void {
    if (!deps.codecs.anyC()) return;

    if (deps.lz4) |dep| {
        module.addIncludePath(dep.path("lib"));
        module.addCSourceFile(.{
            .file = dep.path("lib/lz4.c"),
            .flags = &.{"-DXXH_NAMESPACE=LZ4_"},
        });
    }

    if (deps.brotli) |dep| {
        module.addIncludePath(dep.path("c/include"));
        for (brotli_common_sources) |src| {
            module.addCSourceFile(.{ .file = dep.path(src), .flags = &.{} });
        }
        for (brotli_dec_sources) |src| {
            module.addCSourceFile(.{ .file = dep.path(src), .flags = &.{} });
        }
        for (brotli_enc_sources) |src| {
            module.addCSourceFile(.{ .file = dep.path(src), .flags = &.{} });
        }
    }

    if (deps.snappy) |dep| {
        module.addIncludePath(dep.path(""));
        module.addIncludePath(b.path("src/core/compress"));
        for (snappy_sources) |src| {
            module.addCSourceFile(.{
                .file = dep.path(src),
                .flags = &.{ "-std=c++11", "-DNDEBUG", "-fno-exceptions" },
            });
        }
        module.link_libcpp = true;
    }

    if (deps.zstd) |dep| {
        module.addIncludePath(dep.path("lib"));
        for (zstd_common_sources) |src| {
            module.addCSourceFile(.{ .file = dep.path(src), .flags = zstd_flags });
        }
        for (zstd_compress_sources) |src| {
            module.addCSourceFile(.{ .file = dep.path(src), .flags = zstd_flags });
        }
        for (zstd_decompress_sources) |src| {
            module.addCSourceFile(.{ .file = dep.path(src), .flags = zstd_flags });
        }
    }

    if (deps.zlib) |dep| {
        module.addIncludePath(dep.path(""));
        for (zlib_sources) |src| {
            module.addCSourceFile(.{ .file = dep.path(src), .flags = &.{} });
        }
    }

    module.link_libc = true;
}

// =========================================================================
// C source file lists
// =========================================================================

const brotli_common_sources = &[_][]const u8{
    "c/common/constants.c",
    "c/common/context.c",
    "c/common/dictionary.c",
    "c/common/platform.c",
    "c/common/shared_dictionary.c",
    "c/common/transform.c",
};

const brotli_dec_sources = &[_][]const u8{
    "c/dec/bit_reader.c",
    "c/dec/decode.c",
    "c/dec/huffman.c",
    "c/dec/prefix.c",
    "c/dec/state.c",
    "c/dec/static_init.c",
};

const brotli_enc_sources = &[_][]const u8{
    "c/enc/backward_references.c",
    "c/enc/backward_references_hq.c",
    "c/enc/bit_cost.c",
    "c/enc/block_splitter.c",
    "c/enc/brotli_bit_stream.c",
    "c/enc/cluster.c",
    "c/enc/command.c",
    "c/enc/compound_dictionary.c",
    "c/enc/compress_fragment.c",
    "c/enc/compress_fragment_two_pass.c",
    "c/enc/dictionary_hash.c",
    "c/enc/encode.c",
    "c/enc/encoder_dict.c",
    "c/enc/entropy_encode.c",
    "c/enc/fast_log.c",
    "c/enc/histogram.c",
    "c/enc/literal_cost.c",
    "c/enc/memory.c",
    "c/enc/metablock.c",
    "c/enc/static_dict.c",
    "c/enc/static_dict_lut.c",
    "c/enc/static_init.c",
    "c/enc/utf8_util.c",
};

const snappy_sources = &[_][]const u8{
    "snappy.cc",
    "snappy-c.cc",
    "snappy-sinksource.cc",
    "snappy-stubs-internal.cc",
};

const zstd_flags: []const []const u8 = &.{"-DZSTD_DISABLE_ASM"};

const zstd_common_sources = &[_][]const u8{
    "lib/common/debug.c",
    "lib/common/entropy_common.c",
    "lib/common/error_private.c",
    "lib/common/fse_decompress.c",
    "lib/common/pool.c",
    "lib/common/threading.c",
    "lib/common/xxhash.c",
    "lib/common/zstd_common.c",
};

const zstd_compress_sources = &[_][]const u8{
    "lib/compress/fse_compress.c",
    "lib/compress/hist.c",
    "lib/compress/huf_compress.c",
    "lib/compress/zstd_compress.c",
    "lib/compress/zstd_compress_literals.c",
    "lib/compress/zstd_compress_sequences.c",
    "lib/compress/zstd_compress_superblock.c",
    "lib/compress/zstd_double_fast.c",
    "lib/compress/zstd_fast.c",
    "lib/compress/zstd_lazy.c",
    "lib/compress/zstd_ldm.c",
    "lib/compress/zstd_opt.c",
    "lib/compress/zstd_preSplit.c",
    "lib/compress/zstdmt_compress.c",
};

const zstd_decompress_sources = &[_][]const u8{
    "lib/decompress/huf_decompress.c",
    "lib/decompress/zstd_ddict.c",
    "lib/decompress/zstd_decompress.c",
    "lib/decompress/zstd_decompress_block.c",
};

const zlib_sources = &[_][]const u8{
    "adler32.c",
    "compress.c",
    "crc32.c",
    "deflate.c",
    "inffast.c",
    "inflate.c",
    "inftrees.c",
    "trees.c",
    "uncompr.c",
    "zutil.c",
};
