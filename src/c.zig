/// Shared C import for sqlite3. A single @cImport ensures the opaque type
/// `struct_sqlite3` is identical across all Zig modules that use SQLite.
pub const c = @cImport({
    @cInclude("sqlite3.h");
});
