//! Zig Parquet - A pure Zig implementation of Apache Parquet
//!
//! This library provides reading and writing of Parquet files.
//!
//! ## Reading Example
//! ```zig
//! const parquet = @import("parquet");
//!
//! var reader = try parquet.openFileDynamic(allocator, file, .{});
//! defer reader.deinit();
//!
//! var iter = reader.rowIterator();
//! defer iter.deinit();
//!
//! while (try iter.next()) |row| {
//!     const id = if (row.getColumn(0)) |v| v.asInt32() orelse 0 else 0;
//!     std.debug.print("id={}\n", .{id});
//! }
//! ```
//!
//! ## Writing Example
//! ```zig
//! const parquet = @import("parquet");
//!
//! var writer = try parquet.createFileDynamic(allocator, file);
//! defer writer.deinit();
//!
//! try writer.addColumn("id", parquet.TypeInfo.int64, .{});
//! try writer.begin();
//! try writer.setInt64(0, 1);
//! try writer.addRow();
//! try writer.close();
//! ```

const std = @import("std");

// ============================================================================
// Primary API — Start here
// ============================================================================

// Convenience constructors: the simplest way to read/write Parquet.
//
//   Reading:
//     parquet.openFileDynamic(allocator, file, opts)           -> DynamicReader
//     parquet.openBufferDynamic(allocator, data, opts)         -> DynamicReader
//
//   Writing:
//     parquet.createFileDynamic(allocator, file)               -> DynamicWriter
//     parquet.createBufferDynamic(allocator)                   -> DynamicWriter
//     parquet.writeToFile(allocator, file, columns)            -> Writer (column API)
//     parquet.writeToBuffer(allocator, columns)                -> Writer (column API)
//
// Advanced — transport-neutral constructors on core types:
//     DynamicReader.initFromSeekable(allocator, seekable, opts)
//     DynamicWriter.init(allocator, target)
//     Writer.initWithTarget(allocator, target, columns)
//
// Internals — low-level codec/encoding/format access:
//     parquet.internals.*

// Core types
pub const types = @import("core/types.zig");
pub const Optional = types.Optional;
pub const ReaderError = types.ReaderError;
pub const WriterError = types.WriterError;

// Safety utilities (hardening against malformed input)
pub const safe = @import("core/safe.zig");

// Schema and Value types for nested composition
const schema = @import("core/schema.zig");
pub const SchemaNode = schema.SchemaNode;
const value = @import("core/value.zig");
pub const Value = value.Value;
pub const nested = @import("core/nested.zig");

// Arrow types for zero-copy interop
const arrow = @import("core/arrow.zig");
pub const ArrowSchema = arrow.ArrowSchema;
pub const ArrowArray = arrow.ArrowArray;
pub const ArrowColumn = arrow.ArrowColumn;
pub const ArrowArrayStream = arrow.ArrowArrayStream;

// Arrow batch API (runtime type dispatch for row group I/O)
const arrow_batch = @import("core/arrow_batch.zig");
pub const exportSchemaAsArrow = arrow_batch.exportSchemaAsArrow;
pub const importSchemaFromArrow = arrow_batch.importSchemaFromArrow;
pub const freeImportedColumnDefs = arrow_batch.freeImportedColumnDefs;
pub const readRowGroupAsArrow = arrow_batch.readRowGroupAsArrow;
pub const writeRowGroupFromArrow = arrow_batch.writeRowGroupFromArrow;

// Writer (core type)
const writer_mod = @import("core/writer.zig");
pub const Writer = writer_mod.Writer;
pub const ColumnDef = writer_mod.ColumnDef;
pub const StructField = writer_mod.StructField;

// Write target interface (core)
const write_target_mod = @import("core/write_target.zig");
pub const WriteTarget = write_target_mod.WriteTarget;
pub const WriteError = write_target_mod.WriteError;
pub const WriteTargetWriter = write_target_mod.WriteTargetWriter;

// Format types (Thrift-decoded Parquet structures)
pub const format = @import("core/format.zig");
pub const CompressionCodec = format.CompressionCodec;
pub const SortingColumn = format.SortingColumn;

// Dynamic Writer (runtime row-oriented writing)
const writer_module = @import("core/writer_mod.zig");
pub const DynamicWriter = writer_module.DynamicWriter;
pub const DynamicWriterError = writer_module.DynamicWriterError;
pub const TypeInfo = writer_module.TypeInfo;

// Dynamic Reader (schema-agnostic row reading)
const reader_module = @import("core/reader_mod.zig");
pub const DynamicReader = reader_module.DynamicReader;
pub const DynamicReaderError = reader_module.DynamicReaderError;
pub const DynamicReaderOptions = reader_module.DynamicReaderOptions;
pub const ChecksumOptions = reader_module.ChecksumOptions;
pub const RowIterator = DynamicReader.RowIterator;
pub const Row = value.Row;

// Page-index filtering (read-time skip of pages whose min/max can't match).
pub const page_filter = @import("core/page_filter.zig");
pub const ColumnFilter = page_filter.ColumnFilter;
pub const RowRanges = @import("core/row_ranges.zig").RowRanges;
pub const PageIndexReader = @import("core/page_index_reader.zig").PageIndexReader;

// SeekableReader interface (core)
pub const SeekableReader = reader_module.SeekableReader;
pub const BackendCleanup = reader_module.BackendCleanup;

// IO adapters (transport layer)
pub const io = struct {
    pub const FileReader = @import("io/file_reader.zig").FileReader;
    pub const BufferReader = @import("io/buffer_reader.zig").BufferReader;
    pub const CallbackReader = @import("io/callback_reader.zig").CallbackReader;
    pub const FileTarget = @import("io/file_target.zig").FileTarget;
    pub const BufferTarget = @import("io/buffer_target.zig").BufferTarget;
    pub const CallbackWriter = @import("io/callback_writer.zig").CallbackWriter;
};

// Convenience constructors (api/zig layer)
const api_reader = @import("api/zig/reader.zig");
const api_writer = @import("api/zig/writer.zig");

pub const openFileDynamic = api_reader.openFileDynamic;
pub const openBufferDynamic = api_reader.openBufferDynamic;
pub const writeToFile = api_writer.writeToFile;
pub const writeToBuffer = api_writer.writeToBuffer;
pub const createFileDynamic = api_writer.createFileDynamic;
pub const createBufferDynamic = api_writer.createBufferDynamic;

pub const Decimal = types.Decimal;
pub const DecimalValue = types.DecimalValue;
pub const Int96 = types.Int96;

// ============================================================================
// Internals — Low-level modules for advanced usage
// ============================================================================

pub const internals = struct {
    pub const thrift = @import("core/thrift/mod.zig");
    pub const compress = @import("core/compress/mod.zig");
    pub const reader = @import("core/reader_mod.zig");
    pub const column_decoder = reader.column_decoder;
    pub const encoding = struct {
        pub const plain = @import("core/encoding/plain.zig");
        pub const plain_encoder = @import("core/encoding/plain_encoder.zig");
        pub const rle = @import("core/encoding/rle.zig");
        pub const rle_encoder = @import("core/encoding/rle_encoder.zig");
        pub const dictionary = @import("core/encoding/dictionary.zig");
        pub const delta_binary_packed = @import("core/encoding/delta_binary_packed.zig");
        pub const delta_length_byte_array = @import("core/encoding/delta_length_byte_array.zig");
        pub const delta_byte_array = @import("core/encoding/delta_byte_array.zig");
        pub const byte_stream_split = @import("core/encoding/byte_stream_split.zig");
        pub const byte_stream_split_encoder = @import("core/encoding/byte_stream_split_encoder.zig");
        pub const delta_binary_packed_encoder = @import("core/encoding/delta_binary_packed_encoder.zig");
        pub const delta_length_byte_array_encoder = @import("core/encoding/delta_length_byte_array_encoder.zig");
        pub const delta_byte_array_encoder = @import("core/encoding/delta_byte_array_encoder.zig");
    };
    pub const writer = @import("core/writer_mod.zig");
    pub const geo = @import("core/geo/mod.zig");
};

// ============================================================================
// Tests
// ============================================================================

test {
    _ = safe;
    _ = types;
    _ = internals.thrift;
    _ = format;
    _ = internals.compress;
    _ = internals.column_decoder;
    _ = internals.encoding.plain;
    _ = internals.encoding.plain_encoder;
    _ = internals.encoding.rle;
    _ = internals.encoding.rle_encoder;
    _ = internals.encoding.dictionary;
    _ = internals.encoding.delta_binary_packed;
    _ = internals.encoding.delta_length_byte_array;
    _ = internals.encoding.delta_byte_array;
    _ = internals.encoding.byte_stream_split;
    _ = internals.encoding.byte_stream_split_encoder;
    _ = internals.encoding.delta_binary_packed_encoder;
    _ = internals.encoding.delta_length_byte_array_encoder;
    _ = internals.encoding.delta_byte_array_encoder;
    _ = internals.reader;
    _ = internals.reader.seekable_reader;
    _ = @import("core/writer.zig");
    _ = @import("core/row_ranges.zig");
    _ = @import("core/page_index_reader.zig");
    _ = @import("core/page_filter.zig");
    _ = @import("core/page_range_reader.zig");
    _ = @import("core/page_index_writer.zig");
    _ = internals.writer;
    _ = schema;
    _ = value;
    _ = nested;
    _ = arrow_batch;
    _ = internals.geo;
    _ = api_reader;
    _ = api_writer;
}
