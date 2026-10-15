//! Minimal SQLite bindings. Declared by hand (no C headers needed), which keeps
//! builds fast and avoids translate-c. Links against the system libsqlite3.

const std = @import("std");

pub const c_db = opaque {};
pub const c_stmt = opaque {};

const OK = 0;
const CORRUPT = 11;
const NOTADB = 26;
const ROW = 100;
const DONE = 101;
const OPEN_READONLY = 0x00000001;
const OPEN_READWRITE = 0x00000002;
const OPEN_CREATE = 0x00000004;
const OPEN_FULLMUTEX = 0x00010000;

extern "c" fn sqlite3_open_v2(filename: [*:0]const u8, db: *?*c_db, flags: c_int, vfs: ?[*:0]const u8) c_int;
extern "c" fn sqlite3_close_v2(db: ?*c_db) c_int;
extern "c" fn sqlite3_exec(db: *c_db, sql: [*:0]const u8, cb: ?*const anyopaque, arg: ?*anyopaque, err: ?*?[*:0]u8) c_int;
extern "c" fn sqlite3_prepare_v2(db: *c_db, sql: [*]const u8, n: c_int, stmt: *?*c_stmt, tail: ?*?[*]const u8) c_int;
extern "c" fn sqlite3_step(stmt: *c_stmt) c_int;
extern "c" fn sqlite3_reset(stmt: *c_stmt) c_int;
extern "c" fn sqlite3_finalize(stmt: ?*c_stmt) c_int;
extern "c" fn sqlite3_bind_text(stmt: *c_stmt, idx: c_int, text: [*]const u8, n: c_int, destructor: ?*const anyopaque) c_int;
extern "c" fn sqlite3_bind_int64(stmt: *c_stmt, idx: c_int, v: i64) c_int;
extern "c" fn sqlite3_column_int64(stmt: *c_stmt, col: c_int) i64;
extern "c" fn sqlite3_column_text(stmt: *c_stmt, col: c_int) ?[*]const u8;
extern "c" fn sqlite3_column_bytes(stmt: *c_stmt, col: c_int) c_int;
extern "c" fn sqlite3_errmsg(db: *c_db) [*:0]const u8;

/// `DatabaseCorrupt` means the file is damaged or isn't a database at all (SQLITE_CORRUPT,
/// SQLITE_NOTADB); every other failure is `SqliteError`.
pub const Error = error{ SqliteError, DatabaseCorrupt };

fn check(rc: c_int) Error!void {
    return switch (rc & 0xff) { // the low byte is the primary code, even for extended codes
        OK => {},
        CORRUPT, NOTADB => error.DatabaseCorrupt,
        else => error.SqliteError,
    };
}

pub const Db = struct {
    handle: *c_db,

    pub fn open(path: [:0]const u8) Error!Db {
        return openFlags(path, OPEN_READWRITE | OPEN_CREATE | OPEN_FULLMUTEX);
    }

    /// Opens an existing database without creating it or allowing writes.
    pub fn openReadOnly(path: [:0]const u8) Error!Db {
        return openFlags(path, OPEN_READONLY | OPEN_FULLMUTEX);
    }

    fn openFlags(path: [:0]const u8, flags: c_int) Error!Db {
        var h: ?*c_db = null;
        const rc = sqlite3_open_v2(path.ptr, &h, flags, null);
        if (rc != OK or h == null) {
            _ = sqlite3_close_v2(h);
            return error.SqliteError;
        }
        return .{ .handle = h.? };
    }

    pub fn close(db: Db) void {
        _ = sqlite3_close_v2(db.handle);
    }

    pub fn exec(db: Db, sql: [:0]const u8) Error!void {
        try check(sqlite3_exec(db.handle, sql.ptr, null, null, null));
    }

    pub fn prepare(db: Db, sql: []const u8) Error!Stmt {
        var s: ?*c_stmt = null;
        try check(sqlite3_prepare_v2(db.handle, sql.ptr, @intCast(sql.len), &s, null));
        return .{ .handle = s orelse return error.SqliteError };
    }

    /// `PRAGMA user_version`: a number SQLite stores for the application, 0 in a new database.
    pub fn userVersion(db: Db) Error!i64 {
        const st = try db.prepare("PRAGMA user_version");
        defer st.finalize();
        if (!try st.step()) return error.SqliteError;
        return st.int(0);
    }

    pub fn setUserVersion(db: Db, v: i32) Error!void {
        var buf: [48]u8 = undefined;
        const sql = std.fmt.bufPrintSentinel(&buf, "PRAGMA user_version = {d}", .{v}, 0) catch return error.SqliteError;
        try db.exec(sql);
    }

    pub fn errmsg(db: Db) []const u8 {
        return std.mem.span(sqlite3_errmsg(db.handle));
    }
};

pub const Stmt = struct {
    handle: *c_stmt,

    /// Binds with SQLITE_STATIC: `value` must stay alive until the next step/reset.
    pub fn bindText(s: Stmt, idx: c_int, value: []const u8) Error!void {
        if (sqlite3_bind_text(s.handle, idx, value.ptr, @intCast(value.len), null) != OK) return error.SqliteError;
    }

    pub fn bindInt(s: Stmt, idx: c_int, v: i64) Error!void {
        if (sqlite3_bind_int64(s.handle, idx, v) != OK) return error.SqliteError;
    }

    /// Returns true when a row is available, false when done.
    pub fn step(s: Stmt) Error!bool {
        return switch (sqlite3_step(s.handle)) {
            ROW => true,
            DONE => false,
            else => |rc| {
                try check(rc);
                return error.SqliteError; // OK is not a valid step result
            },
        };
    }

    pub fn reset(s: Stmt) void {
        _ = sqlite3_reset(s.handle);
    }

    pub fn finalize(s: Stmt) void {
        _ = sqlite3_finalize(s.handle);
    }

    pub fn int(s: Stmt, col: c_int) i64 {
        return sqlite3_column_int64(s.handle, col);
    }

    pub fn text(s: Stmt, col: c_int) []const u8 {
        const p = sqlite3_column_text(s.handle, col) orelse return "";
        const n: usize = @intCast(sqlite3_column_bytes(s.handle, col));
        return p[0..n];
    }
};

test "round-trips text and integers through a statement" {
    const db = try Db.open(":memory:");
    defer db.close();
    try db.exec("CREATE TABLE t(a TEXT, b INTEGER)");

    const ins = try db.prepare("INSERT INTO t VALUES(?, ?)");
    defer ins.finalize();
    try ins.bindText(1, "héllo wörld");
    try ins.bindInt(2, std.math.minInt(i64));
    try std.testing.expect(!try ins.step());
    ins.reset();
    try ins.bindText(1, "");
    try ins.bindInt(2, std.math.maxInt(i64));
    try std.testing.expect(!try ins.step());

    const sel = try db.prepare("SELECT a, b FROM t ORDER BY b");
    defer sel.finalize();
    try std.testing.expect(try sel.step());
    try std.testing.expectEqualStrings("héllo wörld", sel.text(0));
    try std.testing.expectEqual(@as(i64, std.math.minInt(i64)), sel.int(1));
    try std.testing.expect(try sel.step());
    try std.testing.expectEqualStrings("", sel.text(0));
    try std.testing.expectEqual(@as(i64, std.math.maxInt(i64)), sel.int(1));
    try std.testing.expect(!try sel.step());
}

test "NULL columns read as empty text" {
    const db = try Db.open(":memory:");
    defer db.close();
    const st = try db.prepare("SELECT NULL");
    defer st.finalize();
    try std.testing.expect(try st.step());
    try std.testing.expectEqualStrings("", st.text(0));
}

test "bad SQL and constraint violations are errors, not crashes" {
    const db = try Db.open(":memory:");
    defer db.close();
    try std.testing.expectError(error.SqliteError, db.exec("NOT SQL"));
    try std.testing.expectError(error.SqliteError, db.prepare("SELECT * FROM missing_table"));
    try std.testing.expect(db.errmsg().len > 0);

    try db.exec("CREATE TABLE u(k TEXT PRIMARY KEY)");
    const st = try db.prepare("INSERT INTO u VALUES(?)");
    defer st.finalize();
    try st.bindText(1, "same");
    try std.testing.expect(!try st.step());
    st.reset();
    try st.bindText(1, "same");
    try std.testing.expectError(error.SqliteError, st.step());
}

test "user_version starts at 0 and round-trips" {
    const db = try Db.open(":memory:");
    defer db.close();
    try std.testing.expectEqual(@as(i64, 0), try db.userVersion());
    try db.setUserVersion(7);
    try std.testing.expectEqual(@as(i64, 7), try db.userVersion());
}

test "a file that isn't a database reports DatabaseCorrupt" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const junk: [4096]u8 = @splat('j');
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "junk.db", .data = &junk });
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(std.testing.io, &buf);
    var path_buf: [std.fs.max_path_bytes + 16]u8 = undefined;
    const path = try std.fmt.bufPrintSentinel(&path_buf, "{s}/junk.db", .{buf[0..n]}, 0);

    const db = try Db.open(path); // opening is lazy; the first read finds the damage
    defer db.close();
    try std.testing.expectError(error.DatabaseCorrupt, db.exec("SELECT * FROM sqlite_schema"));
    try std.testing.expectError(error.DatabaseCorrupt, db.prepare("SELECT * FROM sqlite_schema"));
}

test "opening an unreachable path fails" {
    try std.testing.expectError(error.SqliteError, Db.open("/nonexistent-dir-for-seek-tests/x.db"));
}
