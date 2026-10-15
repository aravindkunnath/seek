//! Minimal SQLite bindings. Declared by hand (no C headers needed), which keeps
//! builds fast and avoids translate-c. Links against the system libsqlite3.

const std = @import("std");

pub const c_db = opaque {};
pub const c_stmt = opaque {};

const OK = 0;
const ROW = 100;
const DONE = 101;
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

pub const Error = error{SqliteError};

pub const Db = struct {
    handle: *c_db,

    pub fn open(path: [:0]const u8) Error!Db {
        var h: ?*c_db = null;
        const rc = sqlite3_open_v2(path.ptr, &h, OPEN_READWRITE | OPEN_CREATE | OPEN_FULLMUTEX, null);
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
        if (sqlite3_exec(db.handle, sql.ptr, null, null, null) != OK) return error.SqliteError;
    }

    pub fn prepare(db: Db, sql: []const u8) Error!Stmt {
        var s: ?*c_stmt = null;
        if (sqlite3_prepare_v2(db.handle, sql.ptr, @intCast(sql.len), &s, null) != OK or s == null)
            return error.SqliteError;
        return .{ .handle = s.? };
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
            else => error.SqliteError,
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
