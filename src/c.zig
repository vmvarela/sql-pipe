/// Shared SQLite3 C bindings, translated from lib/sqlite3.h via addTranslateC.
/// A single import point ensures the opaque type `struct_sqlite3` is identical
/// across all Zig modules that use SQLite.
pub const c = @import("c");
