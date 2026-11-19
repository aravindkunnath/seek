//! The Seek index: SQLite is the source of truth; a compact in-memory snapshot
//! of every path serves as-you-type filename search.
//!
//! Thread safety: `search` and `indexRoot` may run on different threads.
//! Three locks, always taken in this order:
//!   `scan_mutex`  one scan (or other change to which entries exist) at a time. Held for a whole
//!                 scan, including the walk of the disk.
//!   `db_mutex`    one database transaction at a time. Held briefly, never across a walk, so
//!                 listing folders and exclusions doesn't wait for a scan.
//!   `mem_mutex`   the snapshot's contents.
//! The snapshot is changed only while holding all three, so it may be read while holding
//! `scan_mutex` (a scan comparing the disk against it) or `mem_mutex` (a search).

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const sqlite = @import("sqlite.zig");
const fuzzy = @import("fuzzy.zig");

const Index = @This();

gpa: Allocator,
io: Io,
db: sqlite.Db,
scan_mutex: Io.Mutex = .init,
db_mutex: Io.Mutex = .init,
mem_mutex: Io.Mutex = .init,
snap: Snapshot = .{},
err_mutex: Io.Mutex = .init,
err_buf: [error_message_max]u8 = undefined,
err_len: usize = 0,
/// Diagnostics log next to the database (see `logPath`); null when there is no folder for it.
log_path: ?[:0]u8 = null,
log_old_path: ?[:0]u8 = null,

/// Longest remembered error message; longer ones are cut.
pub const error_message_max = 512;
/// When the log grows past this it is moved to `seek.log.1` (replacing the previous one) and restarted.
pub const log_max_bytes = 256 * 1024;

/// Directory names that are never descended into or indexed.
pub const default_excludes = [_][]const u8{
    ".git",       ".hg",                     ".svn",            "node_modules", ".npm",        ".cache",
    ".Trash",     ".zig-cache",              "zig-cache",       "zig-out",      "__pycache__", ".venv",
    ".gradle",    ".cargo",                  ".rustup",         ".nix-defexpr", ".DS_Store",   ".Spotlight-V100",
    ".fseventsd", ".DocumentRevisions-V100", ".TemporaryItems", ".homebrew",
};

/// Directories with these suffixes are macOS bundles: indexed as one entry, not descended into.
const package_suffixes = [_][]const u8{
    ".app",       ".photoslibrary", ".framework", ".bundle",    ".musiclibrary",
    ".tvlibrary", ".imovielibrary", ".fcpbundle", ".xcarchive", ".kext",
    ".plugin",    ".appex",
};

/// `$HOME/Library` is huge and mostly caches, so it's skipped when indexing the home folder.
const home_relative_excludes = [_][]const u8{"Library"};

pub const Entry = struct {
    off: u32, // into Snapshot.buf; path is NUL-terminated there
    len: u32,
    name_off: u32, // basename start, relative to the path
    is_dir: bool,
    size: u64,
    mtime: i64,
    path_mask: u64, // fuzzy.charMask of the path, for fast rejection
    name_mask: u64,
};

const Snapshot = struct {
    /// Every path, each followed by a NUL.
    buf: std.ArrayList(u8) = .empty,
    entries: std.ArrayList(Entry) = .empty,
    /// Bytes of `buf` that belonged to removed entries; `compact` takes them back.
    dead_bytes: usize = 0,

    fn deinit(s: *Snapshot, gpa: Allocator) void {
        s.buf.deinit(gpa);
        s.entries.deinit(gpa);
        s.* = .{};
    }

    pub fn path(s: *const Snapshot, e: Entry) []const u8 {
        return s.buf.items[e.off..][0..e.len];
    }

    /// Adds an entry. Returns false, adding nothing, for a path the snapshot can't hold:
    /// empty, longer than 65,535 bytes, or past 4 GB of paths in total.
    fn append(s: *Snapshot, gpa: Allocator, p: []const u8, size: u64, mtime: i64, is_dir: bool) !bool {
        if (p.len == 0 or p.len > std.math.maxInt(u16)) return false;
        const off = s.buf.items.len;
        if (off + p.len + 1 > std.math.maxInt(u32)) return false;
        try s.buf.ensureUnusedCapacity(gpa, p.len + 1);
        try s.entries.ensureUnusedCapacity(gpa, 1);
        s.buf.appendSliceAssumeCapacity(p);
        s.buf.appendAssumeCapacity(0);
        const name_off: u32 = if (std.mem.findScalarLast(u8, p, '/')) |slash| @intCast(slash + 1) else 0;
        s.entries.appendAssumeCapacity(.{
            .off = @intCast(off),
            .len = @intCast(p.len),
            .name_off = name_off,
            .path_mask = fuzzy.charMask(p),
            .name_mask = fuzzy.charMask(p[name_off..]),
            .is_dir = is_dir,
            .size = size,
            .mtime = mtime,
        });
        return true;
    }

    /// Removes entry `i` by moving the last entry into its place, so only indexes at or
    /// after `i` change meaning.
    fn removeAt(s: *Snapshot, i: usize) void {
        s.dead_bytes += s.entries.items[i].len + 1;
        _ = s.entries.swapRemove(i);
    }

    /// True when removed entries hold more than half of the path bytes.
    fn wantsCompaction(s: *const Snapshot) bool {
        return s.dead_bytes * 2 > s.buf.items.len;
    }

    /// Rewrites `buf` with only the paths still in use. On failure nothing has changed.
    fn compact(s: *Snapshot, gpa: Allocator) !void {
        var fresh: std.ArrayList(u8) = try .initCapacity(gpa, s.buf.items.len - s.dead_bytes);
        for (s.entries.items) |*e| {
            const off = fresh.items.len;
            fresh.appendSliceAssumeCapacity(s.buf.items[e.off..][0 .. e.len + 1]);
            e.off = @intCast(off);
        }
        s.buf.deinit(gpa);
        s.buf = fresh;
        s.dead_bytes = 0;
    }
};

/// Whether `p` lies below the folder `root` (which has no trailing slash, unless it is "/").
fn isUnder(root: []const u8, p: []const u8) bool {
    if (std.mem.eql(u8, root, "/")) return p.len > 1;
    return p.len > root.len and p[root.len] == '/' and std.mem.startsWith(u8, p, root);
}

pub const Hit = struct {
    path: []const u8, // borrowed; valid only while the caller holds the result arena
    name_off: u32,
    is_dir: bool,
    size: u64,
    mtime: i64,
    score: i32,
};

/// Narrows a search. The zero value matches everything.
pub const Filter = struct {
    pub const Scope = enum(u8) { all, files, folders };
    pub const Kind = enum(u8) { any, documents, images, audio, video, code, archives };

    scope: Scope = .all,
    kind: Kind = .any,
    min_size: u64 = 0,
    modified_after: i64 = 0, // seconds since 1970; 0 = any time

    pub fn isActive(f: Filter) bool {
        return f.scope != .all or f.kind != .any or f.min_size != 0 or f.modified_after != 0;
    }

    fn matches(f: Filter, path: []const u8, e: Entry) bool {
        switch (f.scope) {
            .all => {},
            .files => if (e.is_dir) return false,
            .folders => if (!e.is_dir) return false,
        }
        if (f.min_size != 0 and (e.is_dir or e.size < f.min_size)) return false;
        if (f.modified_after != 0 and e.mtime < f.modified_after) return false;
        if (f.kind != .any) {
            if (e.is_dir) return false;
            return kindOf(path[e.name_off..]) == f.kind;
        }
        return true;
    }
};

const kind_exts = [_]struct { Filter.Kind, []const []const u8 }{
    .{ .documents, &.{ "pdf", "doc", "docx", "txt", "md", "rtf", "pages", "odt", "xls", "xlsx", "numbers", "csv", "ppt", "pptx", "key", "epub" } },
    .{ .images, &.{ "png", "jpg", "jpeg", "gif", "heic", "heif", "webp", "tif", "tiff", "bmp", "svg", "raw", "cr2", "nef", "dng", "psd" } },
    .{ .audio, &.{ "mp3", "m4a", "aac", "wav", "flac", "aiff", "ogg", "opus" } },
    .{ .video, &.{ "mp4", "mov", "m4v", "mkv", "avi", "webm" } },
    .{ .code, &.{ "zig", "c", "h", "m", "mm", "cpp", "hpp", "rs", "go", "py", "js", "ts", "tsx", "jsx", "swift", "java", "kt", "rb", "sh", "json", "yaml", "yml", "toml", "html", "css" } },
    .{ .archives, &.{ "zip", "tar", "gz", "tgz", "bz2", "xz", "7z", "rar", "dmg", "iso" } },
};

fn kindOf(name: []const u8) Filter.Kind {
    const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse return .any;
    const ext = name[dot + 1 ..];
    if (ext.len == 0 or ext.len > 8) return .any;
    var buf: [8]u8 = undefined;
    const lower = std.ascii.lowerString(&buf, ext);
    for (kind_exts) |k| for (k[1]) |x| if (std.mem.eql(u8, x, lower)) return k[0];
    return .any;
}

pub const ProgressFn = *const fn (ctx: ?*anyopaque, files_seen: u64) callconv(.c) void;

/// Per-connection settings, applied on every open. The busy timeout lets the app and the CLI
/// share a database: a connection waits for the other's write instead of failing.
const connection_setup =
    \\PRAGMA busy_timeout=5000;
    \\PRAGMA journal_mode=WAL;
    \\PRAGMA synchronous=NORMAL;
;

/// The schema, as steps oldest first: step `i` moves a database from `user_version` i to i + 1.
/// Add a step to change the schema; never edit one that has shipped. Step 1 uses IF NOT EXISTS
/// so databases created before versioning (version 0, tables already present) adopt it as is.
const migrations = [_][:0]const u8{
    \\CREATE TABLE IF NOT EXISTS files(
    \\  id INTEGER PRIMARY KEY,
    \\  path TEXT NOT NULL UNIQUE,
    \\  name TEXT NOT NULL,
    \\  ext TEXT NOT NULL,
    \\  size INTEGER NOT NULL,
    \\  mtime INTEGER NOT NULL,
    \\  is_dir INTEGER NOT NULL,
    \\  seen INTEGER NOT NULL
    \\);
    \\CREATE INDEX IF NOT EXISTS files_size ON files(size);
    \\CREATE TABLE IF NOT EXISTS roots(path TEXT PRIMARY KEY);
    \\CREATE TABLE IF NOT EXISTS excludes(pattern TEXT PRIMARY KEY);
    ,
    // Content hashes for duplicate detection. A row is valid while the file's size and mtime
    // still match it; rows for files that left the index are pruned by `findDuplicates`.
    \\CREATE TABLE hashes(
    \\  path TEXT PRIMARY KEY,
    \\  size INTEGER NOT NULL,
    \\  mtime INTEGER NOT NULL, -- nanoseconds
    \\  hash TEXT NOT NULL
    \\);
    ,
};

/// The `user_version` this build writes and understands.
pub const schema_version: i32 = migrations.len;

/// Brings `db` up to `steps.len`, all steps in one transaction, and returns the version it
/// started at. A version this build doesn't know (newer, or negative) is `UnsupportedSchemaVersion`
/// and leaves the database untouched; so does a failing step.
fn migrate(db: sqlite.Db, steps: []const [:0]const u8) !i64 {
    // The usual case, an up-to-date database, needs no write lock: opening never waits for a
    // running scan in another process, and works on a database it can't write.
    const seen = try db.userVersion();
    if (seen == steps.len) return seen;
    if (seen < 0 or seen > steps.len) return error.UnsupportedSchemaVersion;
    // IMMEDIATE takes the write lock up front, and the version is read again under it, so two
    // processes opening at once can't both migrate.
    try db.exec("BEGIN IMMEDIATE");
    var committed = false;
    defer if (!committed) db.exec("ROLLBACK") catch {};
    const from = try db.userVersion();
    if (from < 0 or from > steps.len) return error.UnsupportedSchemaVersion;
    for (steps[@intCast(from)..]) |sql| try db.exec(sql);
    if (from != steps.len) try db.setUserVersion(@intCast(steps.len));
    try db.exec("COMMIT");
    committed = true;
    return from;
}

/// Opens or creates the index at `db_path` (or ":memory:"), upgrading an older schema in place.
/// A database written by a newer Seek is refused (`UnsupportedSchemaVersion`) and left alone.
/// One that is damaged or isn't a database is moved to `seek.db.corrupt`, provided no other
/// process has it open, and replaced by an empty one that keeps whatever folders and exclusions
/// could still be read; the next scan refills it. That is logged and reported by `lastError`.
pub fn open(gpa: Allocator, io: Io, db_path: [:0]const u8) !*Index {
    const self = try gpa.create(Index);
    errdefer gpa.destroy(self);
    self.* = .{ .gpa = gpa, .io = io, .db = undefined };
    errdefer self.freeLogPaths();
    if (std.fs.path.dirname(db_path)) |dir| {
        self.log_path = try std.fmt.allocPrintSentinel(gpa, "{s}/seek.log", .{dir}, 0);
        self.log_old_path = try std.fmt.allocPrintSentinel(gpa, "{s}/seek.log.1", .{dir}, 0);
    }
    self.openDb(db_path) catch |err| switch (err) {
        error.DatabaseCorrupt => try self.recover(db_path),
        else => |e| return e,
    };
    self.logf("info", "opened index with {d} entries (SQLite {s})", .{ self.fileCount(), sqlite.version() });
    return self;
}

/// Opens the database, migrates it and loads the snapshot. On failure nothing stays open.
fn openDb(self: *Index, db_path: [:0]const u8) !void {
    const db = try sqlite.Db.open(db_path);
    errdefer db.close();
    try db.exec(connection_setup);
    const from = try migrate(db, &migrations);
    self.db = db;
    try self.reload(); // reads every row, so damage in the files table shows up here
    if (from != schema_version) self.logf("info", "database schema {d} -> {d}", .{ from, schema_version });
}

/// Sets a damaged database aside as `<db_path>.corrupt` and opens a fresh one in its place,
/// carrying over the folders and exclusions that can still be read. Returns `DatabaseCorrupt`,
/// changing nothing, when there is no file to set aside or another process has it open.
fn recover(self: *Index, db_path: [:0]const u8) !void {
    const cause = error.DatabaseCorrupt;
    if (std.mem.eql(u8, db_path, ":memory:")) return cause;
    const gpa = self.gpa;
    const Paths = struct { db: [:0]u8, wal: [:0]u8, shm: [:0]u8 };
    var paths: [2]Paths = undefined; // [0] the live name, [1] the set-aside name
    var made: usize = 0;
    defer for (paths[0..made]) |p| {
        gpa.free(p.db);
        gpa.free(p.wal);
        gpa.free(p.shm);
    };
    for (&paths, [_][]const u8{ "", ".corrupt" }) |*p, suffix| {
        const db = try std.fmt.allocPrintSentinel(gpa, "{s}{s}", .{ db_path, suffix }, 0);
        errdefer gpa.free(db);
        const wal = try std.fmt.allocPrintSentinel(gpa, "{s}-wal", .{db}, 0);
        errdefer gpa.free(wal);
        p.* = .{ .db = db, .wal = wal, .shm = try std.fmt.allocPrintSentinel(gpa, "{s}-shm", .{db}, 0) };
        made += 1;
    }
    const live = paths[0];
    const aside = paths[1];

    {
        const fd = lockIfUnused(live.db) orelse return cause;
        defer _ = std.c.close(fd);
        // Leftovers of an earlier set-aside database would otherwise be replayed onto this one.
        _ = std.c.unlink(aside.wal.ptr);
        _ = std.c.unlink(aside.shm.ptr);
        if (std.c.rename(live.db.ptr, aside.db.ptr) != 0) return cause;
        // The write-ahead log belongs to the old file; the fresh database must not start with it.
        // (-shm is only a cache of the log's index.)
        _ = std.c.rename(live.wal.ptr, aside.wal.ptr); // usually absent
        _ = std.c.unlink(live.shm.ptr);
    }
    // If no replacement can be made, put the old file back so the next open tries again.
    errdefer {
        _ = std.c.unlink(live.db.ptr);
        _ = std.c.unlink(live.wal.ptr);
        _ = std.c.unlink(live.shm.ptr);
        _ = std.c.rename(aside.db.ptr, live.db.ptr);
        _ = std.c.rename(aside.wal.ptr, live.wal.ptr);
    }

    const kept_roots = salvage(gpa, aside.db, "SELECT path FROM roots ORDER BY path");
    defer freeRoots(gpa, kept_roots);
    const kept_excludes = salvage(gpa, aside.db, "SELECT pattern FROM excludes ORDER BY pattern");
    defer freeRoots(gpa, kept_excludes);

    try self.openDb(live.db);
    self.logf("warn", "moved the damaged database to {s}", .{aside.db});
    if (self.restoreSettings(kept_roots, kept_excludes)) {
        self.logf("info", "kept {d} folder(s) and {d} exclusion(s)", .{ kept_roots.len, kept_excludes.len });
    } else |err| self.logf("error", "could not carry folders and exclusions over: {t}", .{err});
    self.recordError("the index database was damaged and has been replaced", cause);
}

/// SQLite's shared-lock bytes (`PENDING_BYTE + 2`, 510 bytes; see its os_unix.c). Every open
/// connection to a database holds a read lock on them for as long as it is open.
const sqlite_shared_first = 0x40000000 + 2;
const sqlite_shared_size = 510;

/// Takes a write lock on SQLite's shared-lock bytes, which only succeeds while no other process
/// has the database open. Returns the descriptor holding the lock (close it to release), or null.
/// Locks from this process don't conflict, so the caller must have closed its own connections.
fn lockIfUnused(path: [:0]const u8) ?c_int {
    const fd = std.c.open(path.ptr, .{ .ACCMODE = .RDWR });
    if (fd < 0) return null;
    var fl = std.mem.zeroes(std.c.Flock);
    fl.type = std.c.F.WRLCK;
    fl.whence = std.c.SEEK.SET;
    fl.start = sqlite_shared_first;
    fl.len = sqlite_shared_size;
    if (std.c.fcntl(fd, std.c.F.SETLK, &fl) != 0) {
        _ = std.c.close(fd);
        return null;
    }
    return fd;
}

/// Writes salvaged folders and exclusions into the (fresh) database, all or nothing.
fn restoreSettings(self: *Index, kept_roots: []const []u8, kept_excludes: []const []u8) !void {
    self.db_mutex.lockUncancelable(self.io);
    defer self.db_mutex.unlock(self.io);
    const db = self.db;
    try db.exec("BEGIN");
    var committed = false;
    defer if (!committed) db.exec("ROLLBACK") catch {};
    try insertEach(db, "INSERT OR IGNORE INTO roots(path) VALUES(?)", kept_roots);
    try insertEach(db, "INSERT OR IGNORE INTO excludes(pattern) VALUES(?)", kept_excludes);
    try db.exec("COMMIT");
    committed = true;
}

fn insertEach(db: sqlite.Db, sql: []const u8, values: []const []u8) !void {
    const st = try db.prepare(sql);
    defer st.finalize();
    for (values) |v| {
        st.reset();
        try st.bindText(1, v);
        _ = try st.step();
    }
}

/// Best-effort read of one text column from a database being given up on: whatever can't be
/// read is simply not carried over, so every failure yields an empty list.
fn salvage(gpa: Allocator, db_path: [:0]const u8, sql: []const u8) [][]u8 {
    const db = sqlite.Db.openReadOnly(db_path) catch return &.{};
    defer db.close();
    return textColumn(gpa, db, sql) catch &.{};
}

fn freeLogPaths(self: *Index) void {
    if (self.log_path) |p| self.gpa.free(p);
    if (self.log_old_path) |p| self.gpa.free(p);
}

/// Absolute path of the diagnostics log, or "" when the index has no folder to keep one in
/// (an in-memory database). The file exists once the index has been opened.
pub fn logPath(self: *Index) []const u8 {
    return self.log_path orelse "";
}

const FILE = std.c.FILE;

/// Appends one line, `<UTC time> <level> <message>`, to the log. Best effort: logging must never
/// make an operation fail, so problems writing it are ignored. Safe from any thread.
pub fn logf(self: *Index, level: []const u8, comptime fmt: []const u8, args: anytype) void {
    var msg_buf: [error_message_max]u8 = undefined;
    const msg = std.fmt.bufPrint(&msg_buf, fmt, args) catch &msg_buf; // too long: keep the cut-off text
    self.err_mutex.lockUncancelable(self.io);
    defer self.err_mutex.unlock(self.io);
    self.writeLogLocked(level, msg);
}

fn writeLogLocked(self: *Index, level: []const u8, msg: []const u8) void {
    const path = self.log_path orelse return;
    const io = self.io;
    if (Io.Dir.cwd().statFile(io, path, .{})) |st| {
        if (st.size > log_max_bytes) _ = std.c.rename(path.ptr, self.log_old_path.?.ptr);
    } else |_| {} // not there yet: fopen creates it
    const f = std.c.fopen(path.ptr, "ab") orelse return;
    defer _ = std.c.fclose(f);
    const secs: u64 = @intCast(@max(0, @divTrunc(Io.Timestamp.now(io, .real).nanoseconds, std.time.ns_per_s)));
    const es: std.time.epoch.EpochSeconds = .{ .secs = secs };
    const yd = es.getEpochDay().calculateYearDay();
    const md = yd.calculateMonthDay();
    const ds = es.getDaySeconds();
    var line_buf: [error_message_max + 64]u8 = undefined;
    const line = std.fmt.bufPrint(&line_buf, "{d}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z {s} {s}\n", .{
        yd.year,              md.month.numeric(),      md.day_index + 1,
        ds.getHoursIntoDay(), ds.getMinutesIntoHour(), ds.getSecondsIntoMinute(),
        level,                msg,
    }) catch return;
    _ = std.c.fwrite(line.ptr, 1, line.len, f);
}

/// Remembers `what: error` as the most recent failure (see `lastError`). Safe from any thread.
pub fn recordError(self: *Index, what: []const u8, err: anyerror) void {
    self.err_mutex.lockUncancelable(self.io);
    defer self.err_mutex.unlock(self.io);
    const msg = std.fmt.bufPrint(&self.err_buf, "{s}: {t}", .{ what, err }) catch &self.err_buf; // too long: keep the cut-off text
    self.err_len = msg.len;
    self.writeLogLocked("error", msg);
}

/// Copies the most recent failure message into `out` (cut to fit). Empty when nothing has failed.
pub fn lastError(self: *Index, out: []u8) []const u8 {
    self.err_mutex.lockUncancelable(self.io);
    defer self.err_mutex.unlock(self.io);
    const n = @min(self.err_len, out.len);
    @memcpy(out[0..n], self.err_buf[0..n]);
    return out[0..n];
}

pub fn close(self: *Index) void {
    self.freeLogPaths();
    self.snap.deinit(self.gpa);
    self.db.close();
    self.gpa.destroy(self);
}

/// `$SEEK_DB`, else the platform's per-user data folder. Creates the parent folder.
pub fn defaultDbPath(gpa: Allocator, io: Io) ![:0]u8 {
    if (std.c.getenv("SEEK_DB")) |p| return gpa.dupeSentinel(u8, std.mem.span(p), 0);
    const home = std.mem.span(std.c.getenv("HOME") orelse return error.NoHome);
    const dir = if (@import("builtin").os.tag == .macos)
        try std.fmt.allocPrint(gpa, "{s}/Library/Application Support/Seek", .{home})
    else if (std.c.getenv("XDG_DATA_HOME")) |x|
        try std.fmt.allocPrint(gpa, "{s}/seek", .{std.mem.span(x)})
    else
        try std.fmt.allocPrint(gpa, "{s}/.local/share/seek", .{home});
    defer gpa.free(dir);
    try Io.Dir.cwd().createDirPath(io, dir);
    return std.fmt.allocPrintSentinel(gpa, "{s}/seek.db", .{dir}, 0);
}

// ---------------------------------------------------------------- roots

pub fn addRoot(self: *Index, root: []const u8) !void {
    self.db_mutex.lockUncancelable(self.io);
    defer self.db_mutex.unlock(self.io);
    const st = try self.db.prepare("INSERT OR IGNORE INTO roots(path) VALUES(?)");
    defer st.finalize();
    try st.bindText(1, trimSlash(root));
    _ = try st.step();
}

pub fn roots(self: *Index, gpa: Allocator) ![][]u8 {
    self.db_mutex.lockUncancelable(self.io);
    defer self.db_mutex.unlock(self.io);
    return textColumn(gpa, self.db, "SELECT path FROM roots ORDER BY path");
}

/// Runs `sql` and returns its first column as text, one item per row. Free with `freeRoots`.
fn textColumn(gpa: Allocator, db: sqlite.Db, sql: []const u8) ![][]u8 {
    const st = try db.prepare(sql);
    defer st.finalize();
    var list: std.ArrayList([]u8) = .empty;
    errdefer {
        for (list.items) |r| gpa.free(r);
        list.deinit(gpa);
    }
    while (try st.step()) try list.append(gpa, try gpa.dupe(u8, st.text(0)));
    return list.toOwnedSlice(gpa);
}

pub fn freeRoots(gpa: Allocator, list: [][]u8) void {
    for (list) |r| gpa.free(r);
    gpa.free(list);
}

/// Removes a folder from the index: forgets it and drops every entry under it.
pub fn removeRoot(self: *Index, root_in: []const u8) !void {
    const root = trimSlash(root_in);
    self.scan_mutex.lockUncancelable(self.io);
    defer self.scan_mutex.unlock(self.io);
    self.db_mutex.lockUncancelable(self.io);
    defer self.db_mutex.unlock(self.io);
    {
        const st = try self.db.prepare("DELETE FROM roots WHERE path = ?");
        defer st.finalize();
        try st.bindText(1, root);
        _ = try st.step();
    }
    if (std.mem.eql(u8, root, "/")) {
        try self.db.exec("DELETE FROM files");
    } else {
        const lo = try std.fmt.allocPrint(self.gpa, "{s}/", .{root});
        defer self.gpa.free(lo);
        const hi = try std.fmt.allocPrint(self.gpa, "{s}0", .{root});
        defer self.gpa.free(hi);
        const st = try self.db.prepare("DELETE FROM files WHERE path >= ? AND path < ?");
        defer st.finalize();
        try st.bindText(1, lo);
        try st.bindText(2, hi);
        _ = try st.step();
    }
    try self.reloadLocked();
}

/// Entries currently indexed under `root`. Reads the in-memory snapshot, so it never waits on a scan.
pub fn rootFileCount(self: *Index, root_in: []const u8) u64 {
    const root = trimSlash(root_in);
    self.mem_mutex.lockUncancelable(self.io);
    defer self.mem_mutex.unlock(self.io);
    const snap = &self.snap;
    var n: u64 = 0;
    for (snap.entries.items) |e| {
        if (isUnder(root, snap.path(e))) n += 1;
    }
    return n;
}

/// User exclusions: a name or `*` pattern matched against every file and folder name
/// (`*.log`, `build`), or an absolute path that skips that folder.
/// Adding one takes effect at once: entries it excludes leave the index here, without a scan.
/// Waits for a running scan to finish.
pub fn addExclude(self: *Index, pattern_in: []const u8) !void {
    if (pattern_in.len == 0) return;
    const pattern = if (pattern_in[0] == '/') trimSlash(pattern_in) else pattern_in;
    self.scan_mutex.lockUncancelable(self.io);
    defer self.scan_mutex.unlock(self.io);
    {
        self.db_mutex.lockUncancelable(self.io);
        defer self.db_mutex.unlock(self.io);
        const st = try self.db.prepare("INSERT OR IGNORE INTO excludes(pattern) VALUES(?)");
        defer st.finalize();
        try st.bindText(1, pattern);
        _ = try st.step();
    }
    try self.pruneExcluded(pattern);
}

/// The saved folder that a scan would reach `p` from: the deepest one containing it. When
/// saved folders nest, the inner one is scanned last, so its view of an entry is the one that stays.
fn deepestRoot(root_list: []const []u8, p: []const u8) ?[]const u8 {
    var best: ?[]const u8 = null;
    for (root_list) |r| {
        if (isUnder(r, p) and (best == null or r.len > best.?.len)) best = r;
    }
    return best;
}

/// Whether a scan would leave `p` out because of `pattern`: the same answer `userExcluded`
/// gives during a walk, worked out from the path alone.
fn excludedBy(pattern: []const u8, root_list: []const []u8, p: []const u8) bool {
    const root = deepestRoot(root_list, p) orelse return false;
    if (pattern[0] == '/') {
        // A walk only meets the excluded folder if it lies below the folder being scanned.
        return isUnder(root, pattern) and (std.mem.eql(u8, p, pattern) or isUnder(pattern, p));
    }
    // A name pattern hides an entry when it matches the entry or any folder between it and the root.
    var names = std.mem.tokenizeScalar(u8, p[(if (std.mem.eql(u8, root, "/")) 0 else root.len)..], '/');
    while (names.next()) |name| if (globMatch(pattern, name)) return true;
    return false;
}

/// Removes every entry `pattern` excludes. Caller holds scan_mutex.
fn pruneExcluded(self: *Index, pattern: []const u8) !void {
    const root_list = try self.roots(self.gpa);
    defer freeRoots(self.gpa, root_list);
    const scratch = std.heap.page_allocator;
    const snap = &self.snap;
    var keep: std.DynamicBitSetUnmanaged = try .initFull(scratch, snap.entries.items.len);
    defer keep.deinit(scratch);
    for (snap.entries.items, 0..) |e, i| {
        if (excludedBy(pattern, root_list, snap.path(e))) keep.unset(i);
    }
    const gone = keep.bit_length - keep.count();
    try self.removeMissing(&keep);
    if (gone > 0) self.logf("info", "excluding {s} removed {d} entries", .{ pattern, gone });
}

/// Brings back what a removed exclusion was hiding, scanning no more than it has to: for an
/// absolute path, only the saved folder that contains it; for a name pattern, every saved
/// folder. Call after `removeExclude`. Returns the number of entries seen.
pub fn rescanForPattern(self: *Index, pattern_in: []const u8, progress: ?ProgressFn, ctx: ?*anyopaque) !u64 {
    if (pattern_in.len == 0) return 0;
    if (pattern_in[0] != '/') return self.reindexAll(progress, ctx);
    const pattern = trimSlash(pattern_in);
    const root_list = try self.roots(self.gpa);
    defer freeRoots(self.gpa, root_list);
    var best: ?[]const u8 = null;
    for (root_list) |r| {
        if (isUnder(r, pattern) and (best == null or r.len > best.?.len)) best = r;
    }
    return self.indexRoot(best orelse return 0, progress, ctx);
}

pub fn removeExclude(self: *Index, pattern: []const u8) !void {
    self.db_mutex.lockUncancelable(self.io);
    defer self.db_mutex.unlock(self.io);
    const st = try self.db.prepare("DELETE FROM excludes WHERE pattern = ?");
    defer st.finalize();
    try st.bindText(1, pattern);
    _ = try st.step();
}

pub fn excludes(self: *Index, gpa: Allocator) ![][]u8 {
    self.db_mutex.lockUncancelable(self.io);
    defer self.db_mutex.unlock(self.io);
    return self.excludesLocked(gpa);
}

fn excludesLocked(self: *Index, gpa: Allocator) ![][]u8 {
    return textColumn(gpa, self.db, "SELECT pattern FROM excludes ORDER BY pattern");
}

fn globMatch(pat: []const u8, text: []const u8) bool {
    var p: usize = 0;
    var t: usize = 0;
    var star: ?usize = null;
    var mark: usize = 0;
    while (t < text.len) {
        if (p < pat.len and pat[p] == '*') {
            star = p;
            p += 1;
            mark = t;
        } else if (p < pat.len and pat[p] == text[t]) {
            p += 1;
            t += 1;
        } else if (star) |sp| {
            p = sp + 1;
            mark += 1;
            t = mark;
        } else return false;
    }
    while (p < pat.len and pat[p] == '*') p += 1;
    return p == pat.len;
}

fn userExcluded(patterns: []const []u8, name: []const u8, full: []const u8) bool {
    for (patterns) |pat| {
        if (pat[0] == '/') {
            if (std.mem.eql(u8, full, pat)) return true;
        } else if (globMatch(pat, name)) return true;
    }
    return false;
}

fn trimSlash(p: []const u8) []const u8 {
    return if (p.len > 1 and p[p.len - 1] == '/') p[0 .. p.len - 1] else p;
}

// ---------------------------------------------------------------- indexing

fn isExcluded(name: []const u8) bool {
    for (default_excludes) |ex| if (std.mem.eql(u8, name, ex)) return true;
    return false;
}

fn isPackage(name: []const u8) bool {
    for (package_suffixes) |suf| if (std.mem.endsWith(u8, name, suf)) return true;
    return false;
}

fn extOf(name: []const u8) []const u8 {
    const dot = std.mem.findScalarLast(u8, name, '.') orelse return "";
    if (dot == 0) return "";
    return name[dot + 1 ..];
}

/// One difference between the disk and the index, found by a scan and not yet applied.
const Change = struct {
    off: u32, // path, in `Changes.text`
    len: u32,
    size: u64,
    mtime: i64,
    is_dir: bool,
    /// The snapshot entry this updates; null for a path the index doesn't have yet.
    at: ?u32,
};

const Changes = struct {
    text: std.ArrayList(u8) = .empty,
    items: std.ArrayList(Change) = .empty,

    /// Applied to the index whenever this many have piled up, which bounds a scan's memory and
    /// lets a first scan's results show up while it is still running.
    const batch = 20_000;

    fn deinit(c: *Changes, gpa: Allocator) void {
        c.text.deinit(gpa);
        c.items.deinit(gpa);
    }

    fn add(c: *Changes, gpa: Allocator, p: []const u8, size: u64, mtime: i64, is_dir: bool, at: ?u32) !void {
        try c.items.append(gpa, .{ .off = @intCast(c.text.items.len), .len = @intCast(p.len), .size = size, .mtime = mtime, .is_dir = is_dir, .at = at });
        try c.text.appendSlice(gpa, p);
    }

    fn path(c: *const Changes, ch: Change) []const u8 {
        return c.text.items[ch.off..][0..ch.len];
    }
};

/// Writes `changes` to the database in one transaction, then makes the same changes to the
/// snapshot, and empties the list. Caller holds scan_mutex. If the database write fails the
/// snapshot is left as it was. If the snapshot runs out of memory part-way it is missing
/// entries the database has; the next scan sees them as new and puts them back.
fn applyChanges(self: *Index, changes: *Changes) !void {
    if (changes.items.items.len == 0) return;
    self.db_mutex.lockUncancelable(self.io);
    defer self.db_mutex.unlock(self.io);
    const db = self.db;
    {
        const upsert = try db.prepare(
            \\INSERT INTO files(path, name, ext, size, mtime, is_dir, seen) VALUES(?, ?, ?, ?, ?, ?, 0)
            \\ON CONFLICT(path) DO UPDATE SET size=excluded.size, mtime=excluded.mtime, is_dir=excluded.is_dir
        );
        defer upsert.finalize();
        try db.exec("BEGIN");
        var committed = false;
        defer if (!committed) self.rollback();
        var ext_buf: [32]u8 = undefined;
        for (changes.items.items) |ch| {
            const p = changes.path(ch);
            const name = if (std.mem.findScalarLast(u8, p, '/')) |slash| p[slash + 1 ..] else p;
            const ext_raw = extOf(name);
            upsert.reset();
            try upsert.bindText(1, p);
            try upsert.bindText(2, name);
            try upsert.bindText(3, std.ascii.lowerString(&ext_buf, ext_raw[0..@min(ext_raw.len, ext_buf.len)]));
            try upsert.bindInt(4, @intCast(ch.size));
            try upsert.bindInt(5, ch.mtime);
            try upsert.bindInt(6, @intFromBool(ch.is_dir));
            _ = try upsert.step();
        }
        try db.exec("COMMIT");
        committed = true;
    }

    self.mem_mutex.lockUncancelable(self.io);
    defer self.mem_mutex.unlock(self.io);
    for (changes.items.items) |ch| {
        if (ch.at) |i| {
            const e = &self.snap.entries.items[i];
            e.size = ch.size;
            e.mtime = ch.mtime;
            e.is_dir = ch.is_dir;
        } else {
            _ = try self.snap.append(self.gpa, changes.path(ch), ch.size, ch.mtime, ch.is_dir);
        }
    }
    changes.items.clearRetainingCapacity();
    changes.text.clearRetainingCapacity();
}

/// Abandons the open transaction. If even that fails, SQLite drops the transaction when the
/// connection closes; all that is left to do is say so.
fn rollback(self: *Index) void {
    self.db.exec("ROLLBACK") catch |err| self.logf("warn", "rollback failed: {t} ({s})", .{ err, self.db.errmsg() });
}

/// Removes from the database and the snapshot every entry whose bit in `keep` is clear.
/// `keep` covers the entries the snapshot had when the caller took scan_mutex, which it holds.
fn removeMissing(self: *Index, keep: *const std.DynamicBitSetUnmanaged) !void {
    const missing = keep.bit_length - keep.count();
    if (missing == 0) return;
    self.db_mutex.lockUncancelable(self.io);
    defer self.db_mutex.unlock(self.io);
    const db = self.db;
    {
        const del = try db.prepare("DELETE FROM files WHERE path = ?");
        defer del.finalize();
        try db.exec("BEGIN");
        var committed = false;
        defer if (!committed) self.rollback();
        var gone = keep.iterator(.{ .kind = .unset });
        while (gone.next()) |i| {
            del.reset();
            try del.bindText(1, self.snap.path(self.snap.entries.items[i]));
            _ = try del.step();
        }
        try db.exec("COMMIT");
        committed = true;
    }

    self.mem_mutex.lockUncancelable(self.io);
    defer self.mem_mutex.unlock(self.io);
    // Highest index first: each removal moves the last entry down, and everything above the
    // one being removed has already been decided.
    var gone = keep.iterator(.{ .kind = .unset, .direction = .reverse });
    while (gone.next()) |i| self.snap.removeAt(i);
    if (self.snap.wantsCompaction()) {
        self.snap.compact(self.gpa) catch |err| self.logf("warn", "could not compact the snapshot: {t}", .{err});
    }
}

/// Scans `root` (absolute) and brings the index in line with it: entries that are new or have
/// a different size, time or kind are written, entries no longer on disk are removed, and
/// everything else is left untouched, in the database and in memory. A scan that finds nothing
/// changed writes nothing. Returns the number of entries seen.
pub fn indexRoot(self: *Index, root_in: []const u8, progress: ?ProgressFn, ctx: ?*anyopaque) !u64 {
    const io = self.io;
    const gpa = self.gpa;
    const root = trimSlash(root_in);
    const home = if (std.c.getenv("HOME")) |h| trimSlash(std.mem.span(h)) else "";
    const root_is_home = home.len > 0 and std.mem.eql(u8, root, home);

    var dir = try Io.Dir.openDirAbsolute(io, root, .{ .iterate = true });
    defer dir.close(io);

    self.scan_mutex.lockUncancelable(io);
    defer self.scan_mutex.unlock(io);

    const user_ex = try self.excludes(gpa);
    defer freeRoots(gpa, user_ex);

    // What the index holds under this root now: path -> entry number. Holding scan_mutex keeps
    // the entries where they are until this scan itself removes some, which it does last.
    // Both lookups are sized once and come straight from the system, so the memory goes back
    // the moment the scan ends instead of sitting in the allocator's cache of freed blocks.
    const scratch = std.heap.page_allocator;
    const snap = &self.snap;
    const known_count = snap.entries.items.len;
    var known: std.HashMapUnmanaged(u32, u32, std.hash_map.StringIndexContext, std.hash_map.default_max_load_percentage) = .empty;
    defer known.deinit(scratch);
    const by_offset: std.hash_map.StringIndexContext = .{ .bytes = &snap.buf };
    const by_text: std.hash_map.StringIndexAdapter = .{ .bytes = &snap.buf };
    try known.ensureTotalCapacityContext(scratch, @intCast(known_count), by_offset);
    // A clear bit at the end of the walk means "under this root and not found on disk".
    var keep: std.DynamicBitSetUnmanaged = try .initEmpty(scratch, known_count);
    defer keep.deinit(scratch);
    // Saved folders inside this one. What they hold is theirs to remove: this walk may not reach
    // it (an exclusion can hide it from here but not from there), and that is not a deletion.
    const root_list = try self.roots(gpa);
    defer freeRoots(gpa, root_list);
    var inner_roots: std.ArrayList([]const u8) = .empty;
    defer inner_roots.deinit(gpa);
    for (root_list) |r| if (isUnder(root, r)) try inner_roots.append(gpa, r);
    for (snap.entries.items, 0..) |e, i| {
        const p = snap.path(e);
        if (!isUnder(root, p)) {
            keep.set(i);
            continue;
        }
        known.putAssumeCapacityContext(e.off, @intCast(i), by_offset);
        for (inner_roots.items) |r| if (isUnder(r, p)) {
            keep.set(i);
            break;
        };
    }

    var changes: Changes = .{};
    defer changes.deinit(gpa);

    var walker = try dir.walkSelectively(gpa);
    defer walker.deinit();

    var full: std.ArrayList(u8) = .empty;
    defer full.deinit(gpa);
    var count: u64 = 0;

    while (true) {
        const entry = walker.next(io) catch continue orelse break; // unreadable dirs are skipped
        const name = entry.basename;
        if (isExcluded(name)) continue;
        full.clearRetainingCapacity();
        try full.appendSlice(gpa, if (std.mem.eql(u8, root, "/")) "" else root);
        try full.append(gpa, '/');
        try full.appendSlice(gpa, entry.path);
        if (user_ex.len > 0 and userExcluded(user_ex, name, full.items)) continue;
        if (root_is_home and entry.depth() == 1) {
            var skip = false;
            for (home_relative_excludes) |ex| if (std.mem.eql(u8, name, ex)) {
                skip = true;
            };
            if (skip) continue;
        }

        const is_dir = entry.kind == .directory;
        if (is_dir and !isPackage(name)) walker.enter(io, entry) catch {};

        var size: u64 = 0;
        var mtime: i64 = 0;
        if (entry.dir.statFile(io, name, .{ .follow_symlinks = false })) |st| {
            if (!is_dir) size = st.size;
            mtime = @intCast(@divTrunc(st.mtime.nanoseconds, std.time.ns_per_s));
        } else |_| {}

        if (known.getAdapted(@as([]const u8, full.items), by_text)) |i| {
            keep.set(i);
            const e = snap.entries.items[i];
            if (e.size != size or e.mtime != mtime or e.is_dir != is_dir) try changes.add(gpa, full.items, size, mtime, is_dir, i);
        } else {
            try changes.add(gpa, full.items, size, mtime, is_dir, null);
        }
        if (changes.items.items.len >= Changes.batch) try self.applyChanges(&changes);

        count += 1;
        if (progress) |cb| if (count % 5_000 == 0) cb(ctx, count);
    }

    try self.applyChanges(&changes);
    try self.removeMissing(&keep);
    {
        self.db_mutex.lockUncancelable(io);
        defer self.db_mutex.unlock(io);
        const st = try self.db.prepare("INSERT OR IGNORE INTO roots(path) VALUES(?)");
        defer st.finalize();
        try st.bindText(1, root);
        _ = try st.step();
    }
    if (progress) |cb| cb(ctx, count);

    self.logf("info", "scanned {s}: {d} entries", .{ root, count });
    return count;
}

/// Re-scans every saved root. Returns the total number of entries seen.
/// A root that fails (say, an unmounted drive) doesn't stop the others; the failure is
/// kept for `lastError` and counted in the `failed` out-parameter when given.
pub fn reindexAll(self: *Index, progress: ?ProgressFn, ctx: ?*anyopaque) !u64 {
    return self.reindexAllCounting(progress, ctx, null);
}

pub fn reindexAllCounting(self: *Index, progress: ?ProgressFn, ctx: ?*anyopaque, failed: ?*u32) !u64 {
    const list = try self.roots(self.gpa);
    defer freeRoots(self.gpa, list);
    var total: u64 = 0;
    if (failed) |f| f.* = 0;
    for (list) |r| {
        total += self.indexRoot(r, progress, ctx) catch |err| {
            self.recordError(r, err);
            if (failed) |f| f.* += 1;
            continue;
        };
    }
    return total;
}

// ---------------------------------------------------------------- snapshot

pub fn reload(self: *Index) !void {
    self.scan_mutex.lockUncancelable(self.io);
    defer self.scan_mutex.unlock(self.io);
    self.db_mutex.lockUncancelable(self.io);
    defer self.db_mutex.unlock(self.io);
    try self.reloadLocked();
}

/// Builds a fresh snapshot from SQLite and swaps it in. Caller holds scan_mutex and db_mutex.
fn reloadLocked(self: *Index) !void {
    const gpa = self.gpa;
    var fresh: Snapshot = .{};
    errdefer fresh.deinit(gpa);

    // Size both buffers exactly before filling them. Growing them as rows arrive leaves up to
    // half again as much memory allocated and already written to, which the process keeps.
    {
        const sizes = try self.db.prepare("SELECT COUNT(*), COALESCE(SUM(LENGTH(CAST(path AS BLOB))), 0) FROM files");
        defer sizes.finalize();
        if (try sizes.step()) {
            const rows: usize = @intCast(@max(sizes.int(0), 0));
            const path_bytes: usize = @intCast(@max(sizes.int(1), 0));
            try fresh.entries.ensureTotalCapacityPrecise(gpa, rows);
            try fresh.buf.ensureTotalCapacityPrecise(gpa, @min(path_bytes + rows, std.math.maxInt(u32)));
        }
    }

    const st = try self.db.prepare("SELECT path, size, mtime, is_dir FROM files");
    defer st.finalize();
    while (try st.step()) {
        _ = try fresh.append(gpa, st.text(0), @intCast(@max(st.int(1), 0)), st.int(2), st.int(3) != 0);
    }

    self.mem_mutex.lockUncancelable(self.io);
    std.mem.swap(Snapshot, &self.snap, &fresh);
    self.mem_mutex.unlock(self.io);
    fresh.deinit(gpa);
}

pub fn fileCount(self: *Index) u64 {
    self.mem_mutex.lockUncancelable(self.io);
    defer self.mem_mutex.unlock(self.io);
    return self.snap.entries.items.len;
}

// ---------------------------------------------------------------- search

/// Ranks every indexed path against `query` and writes up to `out.len` hits,
/// best first. Hit paths are copied into `arena` so they outlive snapshot swaps.
const max_hits = 256;
const max_threads = 16;
/// Below this many entries a single thread is faster than spawning workers.
const parallel_threshold = 60_000;

const Ranked = struct { idx: u32, score: i32, len: u32 };

/// Best-k list kept sorted: higher score first, then shorter path.
const TopK = struct {
    buf: [max_hits]Ranked = undefined,
    n: usize = 0,
    k: usize,

    fn better(a: Ranked, b: Ranked) bool {
        return a.score > b.score or (a.score == b.score and a.len < b.len);
    }

    fn insert(t: *TopK, cand: Ranked) void {
        if (t.n == t.k) {
            if (!better(cand, t.buf[t.k - 1])) return;
            t.n -= 1;
        }
        var j = t.n;
        while (j > 0 and better(cand, t.buf[j - 1])) : (j -= 1) t.buf[j] = t.buf[j - 1];
        t.buf[j] = cand;
        t.n += 1;
    }
};

fn scanRange(snap: *const Snapshot, q: *const fuzzy.Query, filter: Filter, now: i64, start: usize, end: usize, top: *TopK) void {
    const filtered = filter.isActive();
    for (snap.entries.items[start..end], start..) |e, i| {
        if (filtered and !filter.matches(snap.path(e), e)) continue;
        const s = fuzzy.score(q, snap.path(e), e.name_off, e.path_mask, e.name_mask, e.mtime, now);
        if (s != 0) top.insert(.{ .idx = @intCast(i), .score = s, .len = e.len });
    }
}

pub fn search(self: *Index, arena: Allocator, query: []const u8, now: i64, out: []Hit) !usize {
    return self.searchFiltered(arena, query, .{}, now, out);
}

pub fn searchFiltered(self: *Index, arena: Allocator, query: []const u8, filter: Filter, now: i64, out: []Hit) !usize {
    const q = fuzzy.Query.parse(query);
    if (q.isEmpty() or out.len == 0) return 0;
    const k = @min(out.len, max_hits);

    self.mem_mutex.lockUncancelable(self.io);
    defer self.mem_mutex.unlock(self.io);
    const snap = &self.snap;
    const total = snap.entries.items.len;

    var top: TopK = .{ .k = k };
    const cpus = std.Thread.getCpuCount() catch 1;
    const nthreads = if (total < parallel_threshold) 1 else @min(cpus, max_threads);

    if (nthreads <= 1) {
        scanRange(snap, &q, filter, now, 0, total, &top);
    } else {
        // Each worker ranks its slice into its own TopK; then merge. Slice 0 runs here.
        var parts: [max_threads]TopK = undefined;
        var threads: [max_threads]?std.Thread = @splat(null);
        const chunk = (total + nthreads - 1) / nthreads;
        for (0..nthreads) |t| {
            parts[t] = .{ .k = k };
            const start = @min(t * chunk, total);
            const end = @min(start + chunk, total);
            if (t == 0) continue;
            threads[t] = std.Thread.spawn(.{}, scanRange, .{ snap, &q, filter, now, start, end, &parts[t] }) catch blk: {
                scanRange(snap, &q, filter, now, start, end, &parts[t]); // fall back to inline
                break :blk null;
            };
        }
        scanRange(snap, &q, filter, now, 0, @min(chunk, total), &parts[0]);
        for (0..nthreads) |t| {
            if (threads[t]) |th| th.join();
            for (parts[t].buf[0..parts[t].n]) |r| top.insert(r);
        }
    }

    const n = top.n;
    for (top.buf[0..n], 0..) |r, i| {
        const e = snap.entries.items[r.idx];
        out[i] = .{
            .path = try arena.dupeSentinel(u8, snap.path(e), 0),
            .name_off = e.name_off,
            .is_dir = e.is_dir,
            .size = e.size,
            .mtime = e.mtime,
            .score = r.score,
        };
    }
    return n;
}

/// Files whose size is exactly `size` (candidates for duplicates; the caller confirms by content).
pub fn sameSize(self: *Index, arena: Allocator, size: u64, out: []Hit) !usize {
    if (size == 0 or out.len == 0) return 0;
    self.mem_mutex.lockUncancelable(self.io);
    defer self.mem_mutex.unlock(self.io);
    const snap = &self.snap;
    var n: usize = 0;
    for (snap.entries.items) |e| {
        if (e.is_dir or e.size != size) continue;
        out[n] = .{
            .path = try arena.dupeSentinel(u8, snap.path(e), 0),
            .name_off = e.name_off,
            .is_dir = false,
            .size = e.size,
            .mtime = e.mtime,
            .score = 0,
        };
        n += 1;
        if (n == out.len) break;
    }
    return n;
}

// ---------------------------------------------------------------- duplicates

pub const DupFile = struct {
    path: [:0]const u8, // borrowed from the arena given to `findDuplicates`
    mtime: i64,
};

/// Files with identical content. `files` has at least two entries, oldest first.
pub const DupGroup = struct {
    size: u64, // of each file
    files: []DupFile,

    /// Bytes freed by keeping one copy.
    pub fn reclaimable(g: DupGroup) u64 {
        return g.size * (g.files.len - 1);
    }
};

/// Called as hashing proceeds with files done and total to hash. A nonzero return cancels.
pub const DupProgressFn = *const fn (ctx: ?*anyopaque, done: u64, total: u64) callconv(.c) c_int;

const hash_len = std.crypto.hash.sha2.Sha256.digest_length;
const hash_chunk = 64 * 1024;

const Candidate = struct {
    path: [:0]const u8,
    size: u64,
    mtime: i64 = 0, // seconds, shown to the user
    inode: u64 = 0, // hard links share one: they free nothing when deleted
    mtime_ns: i64 = 0, // keys the hash cache: an edit within the same second still invalidates it
    state: enum { unchecked, ready, cached, hashed, skipped } = .unchecked,
    hash: [hash_len]u8 = undefined,
};

fn lessBySizeHash(_: void, a: Candidate, b: Candidate) bool {
    if (a.size != b.size) return a.size < b.size;
    return std.mem.order(u8, &a.hash, &b.hash) == .lt;
}

fn lessByInode(_: void, a: Candidate, b: Candidate) bool {
    return a.inode < b.inode;
}

fn lessFile(_: void, a: DupFile, b: DupFile) bool {
    if (a.mtime != b.mtime) return a.mtime < b.mtime;
    return std.mem.lessThan(u8, a.path, b.path);
}

fn moreReclaimable(_: void, a: DupGroup, b: DupGroup) bool {
    if (a.reclaimable() != b.reclaimable()) return a.reclaimable() > b.reclaimable();
    return a.size > b.size;
}

/// SHA-256 of the regular file at `path`, without following a symlink. Null when it can't be
/// read as a whole (gone, unreadable, not a regular file, or no longer `want_size` bytes).
fn hashFile(self: *Index, buf: []u8, path: []const u8, want_size: u64) ?[hash_len]u8 {
    const io = self.io;
    const file = Io.Dir.cwd().openFile(io, path, .{ .follow_symlinks = false }) catch return null;
    defer file.close(io);
    // The path may have been swapped for a pipe or device since it was checked: reading one could block forever.
    const st = file.stat(io) catch return null;
    if (st.kind != .file or st.size != want_size) return null;
    var h = std.crypto.hash.sha2.Sha256.init(.{});
    var off: u64 = 0;
    while (true) {
        const n = file.readPositionalAll(io, buf, off) catch return null;
        h.update(buf[0..n]);
        off += n;
        if (n < buf.len) break;
    }
    if (off != want_size) return null; // grew or shrank while reading
    return h.finalResult();
}

/// Stores the hashes computed in `cands` and forgets hashes of files that left the index.
fn saveHashes(self: *Index, cands: []const Candidate) !void {
    self.db_mutex.lockUncancelable(self.io);
    defer self.db_mutex.unlock(self.io);
    const db = self.db;
    try db.exec("BEGIN");
    var committed = false;
    defer if (!committed) db.exec("ROLLBACK") catch {};
    const put = try db.prepare("INSERT OR REPLACE INTO hashes(path, size, mtime, hash) VALUES(?, ?, ?, ?)");
    defer put.finalize();
    for (cands) |c| {
        if (c.state != .hashed) continue;
        const hex = std.fmt.bytesToHex(c.hash, .lower);
        put.reset();
        try put.bindText(1, c.path);
        try put.bindInt(2, @intCast(c.size));
        try put.bindInt(3, c.mtime_ns);
        try put.bindText(4, &hex);
        _ = try put.step();
    }
    try db.exec("DELETE FROM hashes WHERE path NOT IN (SELECT path FROM files)");
    try db.exec("COMMIT");
    committed = true;
}

/// Groups indexed files that have identical content, most reclaimable space first. Only files of
/// at least `min_size` bytes (empty files never count) that share a size with another are read;
/// hashes are cached by path, size and mtime, so unchanged files cost nothing the second time.
/// Symlinks, folders and files that changed or vanished since the last scan are left out.
/// Paths are copied into `arena`. Reading files takes a while: neither the snapshot nor the
/// database is locked meanwhile, so search and scanning go on. `progress` may cancel the run,
/// which returns `error.Canceled` (hashes already computed are kept).
pub fn findDuplicates(
    self: *Index,
    arena: Allocator,
    min_size: u64,
    progress: ?DupProgressFn,
    ctx: ?*anyopaque,
) ![]DupGroup {
    const io = self.io;
    const gpa = self.gpa;

    // 1. Candidates: files that share a size with another file.
    var cands: std.ArrayList(Candidate) = .empty;
    {
        self.mem_mutex.lockUncancelable(io);
        defer self.mem_mutex.unlock(io);
        const snap = &self.snap;
        const entries = snap.entries.items;
        var order: std.ArrayList(u32) = .empty;
        defer order.deinit(gpa);
        const floor = @max(min_size, 1);
        for (entries, 0..) |e, i| {
            if (!e.is_dir and e.size >= floor) try order.append(gpa, @intCast(i));
        }
        const SizeOrder = struct {
            entries: []const Entry,
            fn less(o: @This(), a: u32, b: u32) bool {
                return o.entries[a].size < o.entries[b].size;
            }
        };
        std.sort.pdq(u32, order.items, SizeOrder{ .entries = entries }, SizeOrder.less);
        var i: usize = 0;
        while (i < order.items.len) {
            const size = entries[order.items[i]].size;
            var j = i + 1;
            while (j < order.items.len and entries[order.items[j]].size == size) j += 1;
            if (j - i >= 2) {
                for (order.items[i..j]) |k| {
                    try cands.append(arena, .{
                        .path = try arena.dupeSentinel(u8, snap.path(entries[k]), 0),
                        .size = size,
                    });
                }
            }
            i = j;
        }
    }

    // 2. Check each is still a regular file of the indexed size; its mtime keys the cache.
    for (cands.items) |*c| {
        const st = Io.Dir.cwd().statFile(io, c.path, .{ .follow_symlinks = false }) catch {
            c.state = .skipped;
            continue;
        };
        if (st.kind != .file or st.size != c.size) {
            c.state = .skipped;
            continue;
        }
        c.mtime = @intCast(@divTrunc(st.mtime.nanoseconds, std.time.ns_per_s));
        c.mtime_ns = @truncate(st.mtime.nanoseconds);
        c.inode = @intCast(st.inode);
        c.state = .ready;
    }

    // 3. Cached hashes.
    {
        self.db_mutex.lockUncancelable(io);
        defer self.db_mutex.unlock(io);
        const st = try self.db.prepare("SELECT hash FROM hashes WHERE path=? AND size=? AND mtime=?");
        defer st.finalize();
        for (cands.items) |*c| {
            if (c.state != .ready) continue;
            st.reset();
            try st.bindText(1, c.path);
            try st.bindInt(2, @intCast(c.size));
            try st.bindInt(3, c.mtime_ns);
            if (try st.step()) {
                if (std.fmt.hexToBytes(&c.hash, st.text(0))) |got| {
                    if (got.len == hash_len) c.state = .cached;
                } else |_| {}
            }
        }
    }

    // 4. Hash the rest, with no lock held.
    var todo: u64 = 0;
    for (cands.items) |c| {
        if (c.state == .ready) todo += 1;
    }
    var canceled = false;
    var done: u64 = 0;
    {
        const buf = try gpa.alloc(u8, hash_chunk);
        defer gpa.free(buf);
        for (cands.items) |*c| {
            if (c.state != .ready) continue;
            if (self.hashFile(buf, c.path, c.size)) |digest| {
                c.hash = digest;
                c.state = .hashed;
            } else {
                c.state = .skipped;
            }
            done += 1;
            if (progress) |cb| if (cb(ctx, done, todo) != 0) {
                canceled = true;
                break;
            };
        }
    }

    // 5. Remember what was hashed. It is only a cache: failing to save it doesn't lose the result.
    self.saveHashes(cands.items) catch |err| self.logf("warn", "duplicates: could not save hashes: {t}", .{err});
    if (canceled) return error.Canceled;

    // 6. Same size and same hash: a group.
    var known: std.ArrayList(Candidate) = .empty;
    defer known.deinit(gpa);
    for (cands.items) |c| {
        if (c.state == .cached or c.state == .hashed) try known.append(gpa, c);
    }
    std.sort.pdq(Candidate, known.items, {}, lessBySizeHash);

    var groups: std.ArrayList(DupGroup) = .empty;
    var i: usize = 0;
    while (i < known.items.len) {
        var j = i + 1;
        while (j < known.items.len and known.items[j].size == known.items[i].size and
            std.mem.eql(u8, &known.items[j].hash, &known.items[i].hash)) j += 1;
        // Names of one file (hard links) count once: removing all but one frees nothing.
        std.sort.pdq(Candidate, known.items[i..j], {}, lessByInode);
        var distinct: usize = 0;
        for (known.items[i..j], 0..) |c, k| {
            if (k == 0 or c.inode != known.items[i + k - 1].inode) {
                known.items[i + distinct] = c;
                distinct += 1;
            }
        }
        if (distinct >= 2) {
            const files = try arena.alloc(DupFile, distinct);
            for (known.items[i..][0..distinct], files) |c, *f| f.* = .{ .path = c.path, .mtime = c.mtime };
            std.sort.pdq(DupFile, files, {}, lessFile);
            try groups.append(arena, .{ .size = known.items[i].size, .files = files });
        }
        i = j;
    }
    std.sort.pdq(DupGroup, groups.items, {}, moreReclaimable);
    var skipped: usize = 0;
    for (cands.items) |c| {
        if (c.state == .skipped) skipped += 1;
    }
    self.logf("info", "duplicates: {d} groups from {d} same-size files ({d} hashed, {d} skipped as unreadable or changed)", .{ groups.items.len, cands.items.len, done, skipped });
    return groups.items;
}

test "index a temp tree and search it" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "docs/tax/node_modules/junk");
    try tmp.dir.createDirPath(io, "Photos.app/Contents");
    inline for (.{ "docs/tax/return-2024.pdf", "docs/invoice.pdf", "docs/tax/node_modules/junk/x.js", "Photos.app/Contents/inner.txt" }) |p| {
        var f = try tmp.dir.createFile(io, p, .{});
        f.close(io);
    }
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(io, &root_buf);
    const root = root_buf[0..root_len];

    var db_buf: [std.fs.max_path_bytes + 16]u8 = undefined;
    const db_path = try std.fmt.bufPrintSentinel(&db_buf, "{s}/t.db", .{root}, 0);

    const idx = try Index.open(gpa, io, db_path);
    defer idx.close();
    _ = try idx.indexRoot(root, null, null);

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    var hits: [10]Hit = undefined;

    const n = try idx.search(arena_state.allocator(), "invoice", 0, &hits);
    try std.testing.expect(n >= 1);
    try std.testing.expect(std.mem.endsWith(u8, hits[0].path, "docs/invoice.pdf"));

    try std.testing.expectEqual(@as(usize, 0), try idx.search(arena_state.allocator(), "x.js", 0, &hits));
    try std.testing.expectEqual(@as(usize, 0), try idx.search(arena_state.allocator(), "inner", 0, &hits));
    try std.testing.expect(try idx.search(arena_state.allocator(), "photos app", 0, &hits) >= 1);
    try std.testing.expect(try idx.search(arena_state.allocator(), "tax 2024", 0, &hits) >= 1);

    // Filters narrow the same ranking.
    try std.testing.expectEqual(@as(usize, 2), try idx.searchFiltered(arena_state.allocator(), "pdf", .{ .kind = .documents }, 0, &hits));
    try std.testing.expectEqual(@as(usize, 0), try idx.searchFiltered(arena_state.allocator(), "pdf", .{ .kind = .images }, 0, &hits));
    try std.testing.expectEqual(@as(usize, 0), try idx.searchFiltered(arena_state.allocator(), "pdf", .{ .min_size = 1 }, 0, &hits)); // empty files
    try std.testing.expect(try idx.searchFiltered(arena_state.allocator(), "docs", .{ .scope = .folders }, 0, &hits) >= 1);
    try std.testing.expectEqual(@as(usize, 0), try idx.searchFiltered(arena_state.allocator(), "pdf", .{ .scope = .folders }, 0, &hits));

    try std.testing.expectEqual(@as(usize, 0), try idx.sameSize(arena_state.allocator(), 0, &hits));

    // User exclusions apply on the next scan and are reversible.
    try idx.addExclude("*.pdf");
    _ = try idx.indexRoot(root, null, null);
    try std.testing.expectEqual(@as(usize, 0), try idx.search(arena_state.allocator(), "invoice", 0, &hits));
    try idx.removeExclude("*.pdf");
    _ = try idx.indexRoot(root, null, null);
    try std.testing.expect(try idx.search(arena_state.allocator(), "invoice", 0, &hits) >= 1);
    try std.testing.expect(globMatch("*.log", "a.log") and !globMatch("*.log", "a.logx") and globMatch("b*d", "bold"));
    try std.testing.expect(idx.rootFileCount(root) >= 3);

    // Deleted files disappear on the next scan.
    try tmp.dir.deleteFile(io, "docs/invoice.pdf");
    _ = try idx.indexRoot(root, null, null);
    try std.testing.expectEqual(@as(usize, 0), try idx.search(arena_state.allocator(), "invoice", 0, &hits));
}

test "removing a root drops its entries" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var f = try tmp.dir.createFile(io, "keepme.txt", .{});
    f.close(io);
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try tmp.dir.realPath(io, &root_buf)];
    var db_buf: [std.fs.max_path_bytes + 16]u8 = undefined;
    const db_path = try std.fmt.bufPrintSentinel(&db_buf, "{s}/t.db", .{root}, 0);
    const idx = try Index.open(gpa, io, db_path);
    defer idx.close();
    _ = try idx.indexRoot(root, null, null);
    try std.testing.expect(idx.rootFileCount(root) >= 1);
    try idx.removeRoot(root);
    try std.testing.expectEqual(@as(u64, 0), idx.rootFileCount(root));
    const list = try idx.roots(gpa);
    defer freeRoots(gpa, list);
    try std.testing.expectEqual(@as(usize, 0), list.len);
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

/// A scratch folder to index plus a scratch database kept outside it, so the database never
/// shows up in its own results.
const Fixture = struct {
    tree: testing.TmpDir,
    db_dir: testing.TmpDir,
    root_buf: [std.fs.max_path_bytes]u8 = undefined,
    root_len: usize = 0,
    db_buf: [std.fs.max_path_bytes + 16]u8 = undefined,
    db_len: usize = 0,

    /// Fixtures hold self-referential buffers, so initialise in place: `var fx: Fixture = undefined; try fx.init();`
    fn init(fx: *Fixture) !void {
        const io = testing.io;
        fx.tree = testing.tmpDir(.{ .iterate = true });
        errdefer fx.tree.cleanup();
        fx.db_dir = testing.tmpDir(.{});
        errdefer fx.db_dir.cleanup();
        fx.root_len = try fx.tree.dir.realPath(io, &fx.root_buf);
        var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
        const dir_len = try fx.db_dir.dir.realPath(io, &dir_buf);
        fx.db_len = (try std.fmt.bufPrint(&fx.db_buf, "{s}/seek.db", .{dir_buf[0..dir_len]})).len;
        fx.db_buf[fx.db_len] = 0;
    }

    fn deinit(fx: *Fixture) void {
        fx.tree.cleanup();
        fx.db_dir.cleanup();
    }

    fn root(fx: *const Fixture) []const u8 {
        return fx.root_buf[0..fx.root_len];
    }

    fn dbPath(fx: *const Fixture) [:0]const u8 {
        return fx.db_buf[0..fx.db_len :0];
    }

    fn touch(fx: *Fixture, path: []const u8) !void {
        try fx.write(path, "");
    }

    fn write(fx: *Fixture, path: []const u8, data: []const u8) !void {
        if (std.fs.path.dirname(path)) |d| try fx.tree.dir.createDirPath(testing.io, d);
        try fx.tree.dir.writeFile(testing.io, .{ .sub_path = path, .data = data });
    }

    fn open(fx: *const Fixture) !*Index {
        return Index.open(testing.allocator, testing.io, fx.dbPath());
    }
};

/// Runs `query` and returns how many hits came back; `hits` holds them, paths owned by `arena`.
fn run(idx: *Index, arena: Allocator, query: []const u8, filter: Filter, hits: []Hit) !usize {
    return idx.searchFiltered(arena, query, filter, 0, hits);
}

fn hasSuffixHit(hits: []const Hit, suffix: []const u8) bool {
    for (hits) |h| if (std.mem.endsWith(u8, h.path, suffix)) return true;
    return false;
}

test "globMatch" {
    const cases = [_]struct { []const u8, []const u8, bool }{
        .{ "*.log", "a.log", true },
        .{ "*.log", "a.logx", false },
        .{ "*.log", ".log", true },
        .{ "b*d", "bold", true },
        .{ "b*d", "bd", true },
        .{ "b*d", "bo", false },
        .{ "*", "", true },
        .{ "*", "anything", true },
        .{ "**", "anything", true },
        .{ "a*b*c", "aXXbYYc", true },
        .{ "a*b*c", "aXXcYYb", false },
        .{ "a*a*a", "aaa", true },
        .{ "a*a*a", "aa", false },
        .{ "build", "build", true },
        .{ "build", "builds", false },
        .{ "build", "Build", false }, // case-sensitive, like the shell
        .{ "", "", true },
        .{ "", "x", false },
        .{ "x", "", false },
        .{ "*x", "", false },
        .{ "?", "?", true }, // no `?` wildcard: it is literal
        .{ "?", "a", false },
    };
    for (cases) |c| try testing.expectEqual(c[2], globMatch(c[0], c[1]));
}

test "globMatch does not go exponential on adversarial patterns" {
    const text: [4000]u8 = @splat('a');
    try testing.expect(!globMatch("a*a*a*a*a*a*a*a*b", &text));
    try testing.expect(globMatch("a*a*a*a*a*a*a*a*a", &text));
}

test "userExcluded matches names by glob and folders by absolute path" {
    var a = "*.log".*;
    var b = "/home/u/private".*;
    const patterns = [_][]u8{ &a, &b };
    try testing.expect(userExcluded(&patterns, "x.log", "/home/u/docs/x.log"));
    try testing.expect(userExcluded(&patterns, "private", "/home/u/private"));
    try testing.expect(!userExcluded(&patterns, "private", "/home/u/docs/private")); // absolute means exact
    try testing.expect(!userExcluded(&patterns, "private-notes", "/home/u/private-notes"));
    try testing.expect(!userExcluded(&.{}, "x.log", "/x.log"));
}

test "trimSlash" {
    try testing.expectEqualStrings("/a/b", trimSlash("/a/b/"));
    try testing.expectEqualStrings("/a/b", trimSlash("/a/b"));
    try testing.expectEqualStrings("/", trimSlash("/"));
    try testing.expectEqualStrings("", trimSlash(""));
}

test "extOf" {
    try testing.expectEqualStrings("pdf", extOf("a.pdf"));
    try testing.expectEqualStrings("gz", extOf("a.tar.gz"));
    try testing.expectEqualStrings("", extOf("Makefile"));
    try testing.expectEqualStrings("", extOf(".bashrc")); // a dotfile has no extension
    try testing.expectEqualStrings("", extOf("trailing."));
    try testing.expectEqualStrings("", extOf(""));
}

test "kindOf classifies by extension, case-insensitively" {
    try testing.expectEqual(Filter.Kind.documents, kindOf("a.PDF"));
    try testing.expectEqual(Filter.Kind.images, kindOf("a.JpEg"));
    try testing.expectEqual(Filter.Kind.audio, kindOf("a.flac"));
    try testing.expectEqual(Filter.Kind.video, kindOf("a.mkv"));
    try testing.expectEqual(Filter.Kind.code, kindOf("main.zig"));
    try testing.expectEqual(Filter.Kind.archives, kindOf("a.tar.gz"));
    try testing.expectEqual(Filter.Kind.any, kindOf("README"));
    try testing.expectEqual(Filter.Kind.any, kindOf("a.unknownext"));
    try testing.expectEqual(Filter.Kind.any, kindOf("trailing."));
    try testing.expectEqual(Filter.Kind.any, kindOf("a.verylongextension")); // longer than the 8-byte buffer
}

test "no extension is claimed by two kinds" {
    for (kind_exts, 0..) |a, i| {
        for (kind_exts[i + 1 ..]) |b| {
            for (a[1]) |x| for (b[1]) |y| try testing.expect(!std.mem.eql(u8, x, y));
        }
        for (a[1]) |x| {
            var lower_buf: [8]u8 = undefined;
            try testing.expect(x.len <= 8); // kindOf can't see longer extensions
            try testing.expectEqualStrings(x, std.ascii.lowerString(&lower_buf, x)); // table is lowercase
        }
    }
}

test "isExcluded and isPackage" {
    for (default_excludes) |name| try testing.expect(isExcluded(name));
    try testing.expect(!isExcluded("src"));
    try testing.expect(!isExcluded("node_modules2"));
    try testing.expect(isPackage("Safari.app"));
    try testing.expect(isPackage("Pics.photoslibrary"));
    try testing.expect(!isPackage("app"));
    try testing.expect(!isPackage("application"));
}

test "default excludes have no duplicates" {
    for (default_excludes, 0..) |a, i| {
        for (default_excludes[i + 1 ..]) |b| try testing.expect(!std.mem.eql(u8, a, b));
    }
}

test "Filter.isActive is false only for the zero value" {
    try testing.expect(!(Filter{}).isActive());
    try testing.expect((Filter{ .scope = .files }).isActive());
    try testing.expect((Filter{ .kind = .code }).isActive());
    try testing.expect((Filter{ .min_size = 1 }).isActive());
    try testing.expect((Filter{ .modified_after = 1 }).isActive());
}

test "Filter.matches" {
    const file: Entry = .{ .off = 0, .len = 0, .name_off = 2, .is_dir = false, .size = 100, .mtime = 500, .path_mask = 0, .name_mask = 0 };
    var dir = file;
    dir.is_dir = true;
    dir.size = 0;
    const path = "/a.pdf";

    try testing.expect((Filter{}).matches(path, file));
    try testing.expect((Filter{}).matches(path, dir));
    try testing.expect((Filter{ .scope = .files }).matches(path, file));
    try testing.expect(!(Filter{ .scope = .files }).matches(path, dir));
    try testing.expect(!(Filter{ .scope = .folders }).matches(path, file));
    try testing.expect((Filter{ .scope = .folders }).matches(path, dir));

    try testing.expect((Filter{ .min_size = 100 }).matches(path, file)); // inclusive
    try testing.expect(!(Filter{ .min_size = 101 }).matches(path, file));
    try testing.expect(!(Filter{ .min_size = 1 }).matches(path, dir)); // folders have no size

    try testing.expect((Filter{ .modified_after = 500 }).matches(path, file)); // inclusive
    try testing.expect(!(Filter{ .modified_after = 501 }).matches(path, file));

    try testing.expect((Filter{ .kind = .documents }).matches(path, file));
    try testing.expect(!(Filter{ .kind = .images }).matches(path, file));
    try testing.expect(!(Filter{ .kind = .documents }).matches("/a.pdf", dir)); // a folder named like a file
}

test "TopK keeps the best k, ordered by score then shorter path" {
    var top: TopK = .{ .k = 3 };
    top.insert(.{ .idx = 0, .score = 10, .len = 5 });
    top.insert(.{ .idx = 1, .score = 30, .len = 5 });
    top.insert(.{ .idx = 2, .score = 20, .len = 5 });
    top.insert(.{ .idx = 3, .score = 5, .len = 5 }); // too weak: dropped
    try testing.expectEqual(@as(usize, 3), top.n);
    try testing.expectEqual(@as(u32, 1), top.buf[0].idx);
    try testing.expectEqual(@as(u32, 2), top.buf[1].idx);
    try testing.expectEqual(@as(u32, 0), top.buf[2].idx);

    top.insert(.{ .idx = 4, .score = 20, .len = 2 }); // ties on score: the shorter path wins
    try testing.expectEqual(@as(u32, 1), top.buf[0].idx);
    try testing.expectEqual(@as(u32, 4), top.buf[1].idx);
    try testing.expectEqual(@as(u32, 2), top.buf[2].idx);
    try testing.expectEqual(@as(usize, 3), top.n);

    top.insert(.{ .idx = 5, .score = 20, .len = 5 }); // exact tie with the last: first come, first kept
    try testing.expectEqual(@as(u32, 2), top.buf[2].idx);
}

test "TopK with k = 1 and k = max_hits" {
    var one: TopK = .{ .k = 1 };
    for (0..10) |i| one.insert(.{ .idx = @intCast(i), .score = @intCast(i), .len = 1 });
    try testing.expectEqual(@as(usize, 1), one.n);
    try testing.expectEqual(@as(u32, 9), one.buf[0].idx);

    var full: TopK = .{ .k = max_hits };
    for (0..max_hits * 2) |i| full.insert(.{ .idx = @intCast(i), .score = @intCast(i), .len = 1 });
    try testing.expectEqual(@as(usize, max_hits), full.n);
    try testing.expectEqual(@as(u32, max_hits * 2 - 1), full.buf[0].idx);
    for (full.buf[1..full.n], 0..) |r, i| try testing.expect(full.buf[i].score >= r.score);
}

test "an empty query, an empty output buffer and an empty index all return nothing" {
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();
    const idx = try fx.open();
    defer idx.close();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var hits: [4]Hit = undefined;

    try testing.expectEqual(@as(usize, 0), try idx.search(arena.allocator(), "anything", 0, &hits));
    try fx.touch("a.txt");
    _ = try idx.indexRoot(fx.root(), null, null);
    try testing.expectEqual(@as(usize, 0), try idx.search(arena.allocator(), "", 0, &hits));
    try testing.expectEqual(@as(usize, 0), try idx.search(arena.allocator(), "   ", 0, &hits));
    try testing.expectEqual(@as(usize, 0), try idx.search(arena.allocator(), "a", 0, hits[0..0]));
    try testing.expectEqual(@as(usize, 1), try idx.search(arena.allocator(), "a.txt", 0, &hits));
}

test "results are capped by the output buffer, best first" {
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();
    try fx.touch("report.txt");
    try fx.touch("deep/er/old-report-copy.txt");
    try fx.touch("deep/er/report-draft.txt");
    const idx = try fx.open();
    defer idx.close();
    _ = try idx.indexRoot(fx.root(), null, null);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    var all: [8]Hit = undefined;
    const n = try idx.search(arena.allocator(), "report", 0, &all);
    try testing.expectEqual(@as(usize, 3), n);
    for (all[1..n], 0..) |h, i| try testing.expect(all[i].score >= h.score);
    try testing.expect(std.mem.endsWith(u8, all[0].path, "/report.txt"));

    var one: [1]Hit = undefined;
    try testing.expectEqual(@as(usize, 1), try idx.search(arena.allocator(), "report", 0, &one));
    try testing.expectEqualStrings(all[0].path, one[0].path);
}

test "hit fields describe the file" {
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();
    try fx.write("sub/data.bin", "12345");
    const idx = try fx.open();
    defer idx.close();
    _ = try idx.indexRoot(fx.root(), null, null);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    var hits: [4]Hit = undefined;
    try testing.expectEqual(@as(usize, 1), try idx.search(arena.allocator(), "data.bin", 0, &hits));
    const h = hits[0];
    try testing.expectEqual(@as(u64, 5), h.size);
    try testing.expect(!h.is_dir);
    try testing.expectEqualStrings("data.bin", h.path[h.name_off..]);
    try testing.expect(h.mtime > 0);
    try testing.expect(h.score > 0);
    try testing.expectEqual(@as(u8, 0), h.path.ptr[h.path.len]); // NUL-terminated for the C API

    try testing.expectEqual(@as(usize, 1), try idx.searchFiltered(arena.allocator(), "sub", .{ .scope = .folders }, 0, &hits));
    try testing.expect(hits[0].is_dir);
    try testing.expectEqual(@as(u64, 0), hits[0].size);
}

test "filters combine" {
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();
    try fx.write("small.pdf", "x");
    try fx.write("big.pdf", &@as([2000]u8, @splat('x')));
    try fx.write("big.png", &@as([2000]u8, @splat('x')));
    const idx = try fx.open();
    defer idx.close();
    _ = try idx.indexRoot(fx.root(), null, null);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var hits: [8]Hit = undefined;
    const a = arena.allocator();

    try testing.expectEqual(@as(usize, 2), try run(idx, a, "big", .{}, &hits));
    try testing.expectEqual(@as(usize, 1), try run(idx, a, "big", .{ .kind = .images }, &hits));
    const n = try run(idx, a, ".", .{ .kind = .documents, .min_size = 1000 }, &hits);
    try testing.expectEqual(@as(usize, 1), n);
    try testing.expect(hasSuffixHit(hits[0..n], "big.pdf"));
    try testing.expectEqual(@as(usize, 0), try run(idx, a, ".", .{ .kind = .documents, .min_size = 5000 }, &hits));
    try testing.expectEqual(@as(usize, 0), try run(idx, a, ".", .{ .modified_after = std.math.maxInt(i64) }, &hits));
    try testing.expect(try run(idx, a, ".", .{ .modified_after = 1 }, &hits) >= 3);
}

test "sameSize finds files of exactly that size and respects the buffer" {
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();
    try fx.write("a.bin", "1234");
    try fx.write("d/b.bin", "abcd");
    try fx.write("c.bin", "123");
    try fx.tree.dir.createDirPath(testing.io, "dir4");
    const idx = try fx.open();
    defer idx.close();
    _ = try idx.indexRoot(fx.root(), null, null);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var hits: [8]Hit = undefined;

    const n = try idx.sameSize(arena.allocator(), 4, &hits);
    try testing.expectEqual(@as(usize, 2), n);
    try testing.expect(hasSuffixHit(hits[0..n], "/a.bin") and hasSuffixHit(hits[0..n], "/b.bin"));
    for (hits[0..n]) |h| try testing.expectEqual(@as(u64, 4), h.size);
    try testing.expectEqual(@as(usize, 1), try idx.sameSize(arena.allocator(), 4, hits[0..1]));
    try testing.expectEqual(@as(usize, 0), try idx.sameSize(arena.allocator(), 4, hits[0..0]));
    try testing.expectEqual(@as(usize, 0), try idx.sameSize(arena.allocator(), 999, &hits));
    try testing.expectEqual(@as(usize, 0), try idx.sameSize(arena.allocator(), 0, &hits));
}

test "the index persists across close and open" {
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();
    try fx.touch("persisted.txt");
    {
        const idx = try fx.open();
        defer idx.close();
        try idx.addExclude("*.tmp");
        _ = try idx.indexRoot(fx.root(), null, null);
    }
    const idx = try fx.open();
    defer idx.close();
    try testing.expect(idx.fileCount() >= 1);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var hits: [4]Hit = undefined;
    try testing.expectEqual(@as(usize, 1), try idx.search(arena.allocator(), "persisted", 0, &hits));

    const roots_now = try idx.roots(testing.allocator);
    defer freeRoots(testing.allocator, roots_now);
    try testing.expectEqual(@as(usize, 1), roots_now.len);
    try testing.expectEqualStrings(fx.root(), roots_now[0]);
    const ex = try idx.excludes(testing.allocator);
    defer freeRoots(testing.allocator, ex);
    try testing.expectEqual(@as(usize, 1), ex.len);
    try testing.expectEqualStrings("*.tmp", ex[0]);
}

test "roots are deduplicated, sorted and stored without a trailing slash" {
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();
    const idx = try fx.open();
    defer idx.close();
    try idx.addRoot("/zeta/");
    try idx.addRoot("/zeta");
    try idx.addRoot("/alpha");
    const list = try idx.roots(testing.allocator);
    defer freeRoots(testing.allocator, list);
    try testing.expectEqual(@as(usize, 2), list.len);
    try testing.expectEqualStrings("/alpha", list[0]);
    try testing.expectEqualStrings("/zeta", list[1]);
}

test "excludes: empty patterns are ignored, absolute ones lose their trailing slash" {
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();
    const idx = try fx.open();
    defer idx.close();
    try idx.addExclude("");
    try idx.addExclude("/some/dir/");
    try idx.addExclude("*.log");
    try idx.addExclude("*.log");
    {
        const list = try idx.excludes(testing.allocator);
        defer freeRoots(testing.allocator, list);
        try testing.expectEqual(@as(usize, 2), list.len);
        try testing.expectEqualStrings("*.log", list[0]); // '*' sorts before '/'
        try testing.expectEqualStrings("/some/dir", list[1]);
    }
    try idx.removeExclude("*.log");
    try idx.removeExclude("never-added"); // not an error
    const list = try idx.excludes(testing.allocator);
    defer freeRoots(testing.allocator, list);
    try testing.expectEqual(@as(usize, 1), list.len);
}

test "excluding a folder by absolute path skips everything under it" {
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();
    try fx.touch("keep/a.txt");
    try fx.touch("secret/b.txt");
    try fx.touch("secret-not/c.txt");
    const idx = try fx.open();
    defer idx.close();
    const abs = try std.fmt.allocPrint(testing.allocator, "{s}/secret", .{fx.root()});
    defer testing.allocator.free(abs);
    try idx.addExclude(abs);
    _ = try idx.indexRoot(fx.root(), null, null);

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var hits: [8]Hit = undefined;
    try testing.expectEqual(@as(usize, 0), try idx.search(arena.allocator(), "b.txt", 0, &hits));
    try testing.expectEqual(@as(usize, 1), try idx.search(arena.allocator(), "a.txt", 0, &hits));
    try testing.expectEqual(@as(usize, 1), try idx.search(arena.allocator(), "c.txt", 0, &hits));
}

test "default excludes and packages: bundles are one entry, junk folders are absent" {
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();
    try fx.touch(".git/config");
    try fx.touch("node_modules/pkg/index.js");
    try fx.touch("Thing.app/Contents/Info.txt");
    try fx.touch("visible.txt");
    const idx = try fx.open();
    defer idx.close();
    const n = try idx.indexRoot(fx.root(), null, null);
    try testing.expectEqual(@as(u64, 2), n); // Thing.app and visible.txt
    try testing.expectEqual(@as(u64, 2), idx.fileCount());
}

test "indexRoot reports progress and returns the final count" {
    const Ctx = struct {
        calls: u32 = 0,
        last: u64 = 0,
        fn cb(ctx: ?*anyopaque, n: u64) callconv(.c) void {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            self.calls += 1;
            self.last = n;
        }
    };
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();
    for (0..7) |i| {
        var name_buf: [16]u8 = undefined;
        try fx.touch(try std.fmt.bufPrint(&name_buf, "f{d}.txt", .{i}));
    }
    const idx = try fx.open();
    defer idx.close();
    var ctx: Ctx = .{};
    const n = try idx.indexRoot(fx.root(), Ctx.cb, &ctx);
    try testing.expectEqual(@as(u64, 7), n);
    try testing.expect(ctx.calls >= 1); // at least the final report
    try testing.expectEqual(@as(u64, 7), ctx.last);
}

test "indexing a missing folder is an error and leaves the index untouched" {
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();
    try fx.touch("a.txt");
    const idx = try fx.open();
    defer idx.close();
    _ = try idx.indexRoot(fx.root(), null, null);
    const before = idx.fileCount();
    try testing.expect(std.meta.isError(idx.indexRoot("/definitely/not/a/real/folder", null, null)));
    try testing.expectEqual(before, idx.fileCount());
    const list = try idx.roots(testing.allocator);
    defer freeRoots(testing.allocator, list);
    try testing.expectEqual(@as(usize, 1), list.len); // the bad path was not recorded as a root
}

test "a trailing slash on the root changes nothing" {
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();
    try fx.touch("a.txt");
    const idx = try fx.open();
    defer idx.close();
    const slashed = try std.fmt.allocPrint(testing.allocator, "{s}/", .{fx.root()});
    defer testing.allocator.free(slashed);
    try testing.expectEqual(@as(u64, 1), try idx.indexRoot(slashed, null, null));
    try testing.expectEqual(@as(u64, 1), idx.rootFileCount(slashed));
    try testing.expectEqual(@as(u64, 1), idx.rootFileCount(fx.root()));
}

test "re-indexing is idempotent and picks up new and changed files" {
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();
    try fx.write("a.txt", "1");
    const idx = try fx.open();
    defer idx.close();
    try testing.expectEqual(@as(u64, 1), try idx.indexRoot(fx.root(), null, null));
    try testing.expectEqual(@as(u64, 1), try idx.indexRoot(fx.root(), null, null));
    try testing.expectEqual(@as(u64, 1), idx.fileCount());

    try fx.write("a.txt", "123456");
    try fx.touch("b.txt");
    try testing.expectEqual(@as(u64, 2), try idx.indexRoot(fx.root(), null, null));
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var hits: [4]Hit = undefined;
    try testing.expectEqual(@as(usize, 1), try idx.search(arena.allocator(), "a.txt", 0, &hits));
    try testing.expectEqual(@as(u64, 6), hits[0].size);
}

test "loading sizes the snapshot to fit, with nothing spare" {
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();
    for (0..300) |i| {
        var buf: [48]u8 = undefined;
        try fx.touch(try std.fmt.bufPrint(&buf, "sub/naïve-{d}.txt", .{i})); // bytes, not characters
    }
    {
        const idx = try fx.open();
        defer idx.close();
        _ = try idx.indexRoot(fx.root(), null, null);
    }
    const idx = try fx.open();
    defer idx.close();
    try testing.expectEqual(@as(usize, 301), idx.snap.entries.items.len);
    try testing.expectEqual(idx.snap.entries.items.len, idx.snap.entries.capacity);
    try testing.expectEqual(idx.snap.buf.items.len, idx.snap.buf.capacity);
}

test "a rescan with nothing changed writes no rows" {
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();
    try fx.write("a.txt", "1");
    try fx.write("sub/b.txt", "22");
    const idx = try fx.open();
    defer idx.close();
    try testing.expectEqual(@as(u64, 3), try idx.indexRoot(fx.root(), null, null));
    const before = idx.db.totalChanges();
    try testing.expectEqual(@as(u64, 3), try idx.indexRoot(fx.root(), null, null));
    try testing.expectEqual(before, idx.db.totalChanges());
    try testing.expectEqual(@as(u64, 3), idx.fileCount());
}

test "a rescan writes only the rows that changed" {
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();
    for ([_][]const u8{ "keep1.txt", "keep2.txt", "keep3.txt", "edit.txt", "gone.txt" }) |f| try fx.write(f, "x");
    const idx = try fx.open();
    defer idx.close();
    try setMtime(&fx, "edit.txt", 1_000);
    _ = try idx.indexRoot(fx.root(), null, null);
    const before = idx.db.totalChanges();
    // Same modification time, different size: still a change.
    try fx.write("edit.txt", "longer now");
    try setMtime(&fx, "edit.txt", 1_000);
    try fx.touch("new.txt");
    try fx.tree.dir.deleteFile(testing.io, "gone.txt");
    try testing.expectEqual(@as(u64, 5), try idx.indexRoot(fx.root(), null, null));
    // One update, one insert, one delete.
    try testing.expectEqual(before + 3, idx.db.totalChanges());

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var hits: [8]Hit = undefined;
    try testing.expectEqual(@as(usize, 1), try idx.search(arena.allocator(), "edit.txt", 0, &hits));
    try testing.expectEqual(@as(u64, 10), hits[0].size);
    try testing.expectEqual(@as(usize, 1), try idx.search(arena.allocator(), "new.txt", 0, &hits));
    try testing.expectEqual(@as(usize, 0), try idx.search(arena.allocator(), "gone.txt", 0, &hits));
    try testing.expectEqual(@as(usize, 3), try idx.search(arena.allocator(), "keep", 0, &hits));
}

/// Every snapshot entry as "path|size|mtime|is_dir", sorted, so two snapshots can be compared.
fn snapshotLines(idx: *Index, arena: Allocator) ![][]const u8 {
    var lines: std.ArrayList([]const u8) = .empty;
    for (idx.snap.entries.items) |e| {
        const p = idx.snap.path(e);
        try testing.expectEqual(@as(u8, 0), idx.snap.buf.items[e.off + e.len]);
        try testing.expectEqual(fuzzy.charMask(p), e.path_mask);
        try testing.expectEqual(fuzzy.charMask(p[e.name_off..]), e.name_mask);
        try lines.append(arena, try std.fmt.allocPrint(arena, "{s}|{d}|{d}|{}", .{ p, e.size, e.mtime, e.is_dir }));
    }
    const Less = struct {
        fn f(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    };
    std.mem.sort([]const u8, lines.items, {}, Less.f);
    return lines.items;
}

fn expectSnapshotMatchesDatabase(idx: *Index) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const patched = try snapshotLines(idx, arena.allocator());
    try idx.reload();
    const loaded = try snapshotLines(idx, arena.allocator());
    try testing.expectEqual(loaded.len, patched.len);
    for (loaded, patched) |want, got| try testing.expectEqualStrings(want, got);
}

test "a snapshot patched by rescans is the one a fresh load would build" {
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();
    for (0..40) |i| {
        var buf: [48]u8 = undefined;
        try fx.write(try std.fmt.bufPrint(&buf, "d{d}/sub/file{d}.txt", .{ i % 5, i }), "abc");
    }
    const idx = try fx.open();
    defer idx.close();
    _ = try idx.indexRoot(fx.root(), null, null);
    try expectSnapshotMatchesDatabase(idx);

    // Edits, additions, a deleted folder, and a file that becomes a folder.
    try fx.write("d0/sub/file0.txt", "a much longer body");
    try fx.write("d1/brand/new.md", "n");
    try fx.tree.dir.deleteTree(testing.io, "d2");
    try fx.tree.dir.deleteFile(testing.io, "d3/sub/file3.txt");
    try fx.write("d3/sub/file3.txt/inside.txt", "now a folder");
    _ = try idx.indexRoot(fx.root(), null, null);
    try expectSnapshotMatchesDatabase(idx);
    var d2_buf: [std.fs.max_path_bytes]u8 = undefined;
    try testing.expectEqual(@as(u64, 0), idx.rootFileCount(try std.fmt.bufPrint(&d2_buf, "{s}/d2", .{fx.root()})));

    // Everything goes.
    for (0..5) |i| {
        var buf: [8]u8 = undefined;
        try fx.tree.dir.deleteTree(testing.io, try std.fmt.bufPrint(&buf, "d{d}", .{i}));
    }
    try testing.expectEqual(@as(u64, 0), try idx.indexRoot(fx.root(), null, null));
    try testing.expectEqual(@as(u64, 0), idx.fileCount());
    try expectSnapshotMatchesDatabase(idx);
}

test "removed entries give their path bytes back" {
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();
    for (0..200) |i| {
        var buf: [48]u8 = undefined;
        try fx.touch(try std.fmt.bufPrint(&buf, "bulk/a-rather-long-file-name-{d}.txt", .{i}));
    }
    try fx.touch("stays.txt");
    const idx = try fx.open();
    defer idx.close();
    _ = try idx.indexRoot(fx.root(), null, null);
    const full = idx.snap.buf.items.len;

    try fx.tree.dir.deleteTree(testing.io, "bulk");
    try testing.expectEqual(@as(u64, 1), try idx.indexRoot(fx.root(), null, null));
    try testing.expectEqual(@as(usize, 0), idx.snap.dead_bytes);
    try testing.expect(idx.snap.buf.items.len < full / 50);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var hits: [4]Hit = undefined;
    try testing.expectEqual(@as(usize, 1), try idx.search(arena.allocator(), "stays", 0, &hits));
    try testing.expect(std.mem.endsWith(u8, hits[0].path, "/stays.txt"));
    try expectSnapshotMatchesDatabase(idx);
}

test "scanning one root leaves another root's entries and rows alone" {
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();
    try fx.write("one/a.txt", "1");
    try fx.write("two/b.txt", "2");
    const idx = try fx.open();
    defer idx.close();
    var one_buf: [std.fs.max_path_bytes]u8 = undefined;
    const one = try std.fmt.bufPrint(&one_buf, "{s}/one", .{fx.root()});
    var two_buf: [std.fs.max_path_bytes]u8 = undefined;
    const two = try std.fmt.bufPrint(&two_buf, "{s}/two", .{fx.root()});
    _ = try idx.indexRoot(one, null, null);
    _ = try idx.indexRoot(two, null, null);

    try fx.tree.dir.deleteFile(testing.io, "one/a.txt");
    const before = idx.db.totalChanges();
    _ = try idx.indexRoot(two, null, null); // one/a.txt is gone from disk, but `one` wasn't scanned
    try testing.expectEqual(before, idx.db.totalChanges());
    try testing.expectEqual(@as(u64, 1), idx.rootFileCount(one));
    _ = try idx.indexRoot(one, null, null);
    try testing.expectEqual(@as(u64, 0), idx.rootFileCount(one));
    try testing.expectEqual(@as(u64, 1), idx.rootFileCount(two));
    try expectSnapshotMatchesDatabase(idx);
}

const ListDuringScan = struct {
    idx: *Index,
    calls: u32 = 0,
    listed: u32 = 0,

    fn cb(ctx: ?*anyopaque, _: u64) callconv(.c) void {
        const self: *ListDuringScan = @ptrCast(@alignCast(ctx.?));
        self.calls += 1;
        // On the scanning thread itself: these would never return if the scan held the database lock.
        const r = self.idx.roots(testing.allocator) catch return;
        defer freeRoots(testing.allocator, r);
        const ex = self.idx.excludes(testing.allocator) catch return;
        defer freeRoots(testing.allocator, ex);
        self.listed += 1;
    }
};

test "folders and exclusions can be listed in the middle of a scan" {
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();
    for (0..5_200) |i| {
        var buf: [32]u8 = undefined;
        try fx.touch(try std.fmt.bufPrint(&buf, "d{d}/f{d}", .{ i % 20, i }));
    }
    const idx = try fx.open();
    defer idx.close();
    try idx.addExclude("*.tmp");
    var probe: ListDuringScan = .{ .idx = idx };
    _ = try idx.indexRoot(fx.root(), ListDuringScan.cb, &probe);
    try testing.expect(probe.calls >= 2); // at 5,000 entries and at the end
    try testing.expectEqual(probe.calls, probe.listed);
}

/// A rescan of everything that changes nothing proves the index already is what a scan would build.
fn expectRescanChangesNothing(idx: *Index) !void {
    const before = idx.db.totalChanges();
    _ = try idx.reindexAll(null, null);
    try testing.expectEqual(before, idx.db.totalChanges());
}

test "adding an exclusion removes what it excludes without a scan" {
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();
    for ([_][]const u8{ "a.log", "keep.txt", "build/x.txt", "deep/build/y.txt", "deep/builder.txt", "skip/inner/z.txt", "skipped.txt" }) |f| try fx.touch(f);
    const idx = try fx.open();
    defer idx.close();
    try testing.expectEqual(@as(u64, 12), try idx.indexRoot(fx.root(), null, null));

    try idx.addExclude("*.log");
    try testing.expectEqual(@as(u64, 11), idx.fileCount());
    try idx.addExclude("build"); // the folder, twice, and what is inside each
    try testing.expectEqual(@as(u64, 7), idx.fileCount());
    var skip_buf: [std.fs.max_path_bytes]u8 = undefined;
    try idx.addExclude(try std.fmt.bufPrint(&skip_buf, "{s}/skip/", .{fx.root()}));
    try testing.expectEqual(@as(u64, 4), idx.fileCount()); // keep.txt, deep, deep/builder.txt, skipped.txt

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var hits: [8]Hit = undefined;
    try testing.expectEqual(@as(usize, 0), try idx.search(arena.allocator(), "y.txt", 0, &hits));
    try testing.expectEqual(@as(usize, 1), try idx.search(arena.allocator(), "builder", 0, &hits));
    try testing.expectEqual(@as(usize, 1), try idx.search(arena.allocator(), "skipped", 0, &hits));
    try expectSnapshotMatchesDatabase(idx);
    try expectRescanChangesNothing(idx);
}

test "an exclusion that matches nothing, or is added twice, changes no entries" {
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();
    try fx.touch("a.txt");
    const idx = try fx.open();
    defer idx.close();
    _ = try idx.indexRoot(fx.root(), null, null);
    try idx.addExclude("*.nothing");
    try idx.addExclude("/somewhere/else");
    const before = idx.db.totalChanges();
    try idx.addExclude("*.nothing");
    try testing.expectEqual(before, idx.db.totalChanges());
    try testing.expectEqual(@as(u64, 1), idx.fileCount());
}

test "a folder saved inside another saved folder keeps its entries across rescans" {
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();
    try fx.touch("outer/b/inside.txt");
    try fx.touch("outer/b/gone.txt");
    const idx = try fx.open();
    defer idx.close();
    var outer_buf: [std.fs.max_path_bytes]u8 = undefined;
    const outer = try std.fmt.bufPrint(&outer_buf, "{s}/outer", .{fx.root()});
    var inner_buf: [std.fs.max_path_bytes]u8 = undefined;
    const inner = try std.fmt.bufPrint(&inner_buf, "{s}/outer/b", .{fx.root()});
    _ = try idx.indexRoot(outer, null, null);
    _ = try idx.indexRoot(inner, null, null);
    try idx.addExclude("b"); // hides the folder from `outer`, not from itself
    try expectRescanChangesNothing(idx);
    try testing.expectEqual(@as(u64, 2), idx.rootFileCount(inner));

    // A file deleted inside the inner folder is noticed by the inner folder's scan.
    try fx.tree.dir.deleteFile(testing.io, "outer/b/gone.txt");
    _ = try idx.indexRoot(outer, null, null);
    try testing.expectEqual(@as(u64, 2), idx.rootFileCount(inner));
    _ = try idx.indexRoot(inner, null, null);
    try testing.expectEqual(@as(u64, 1), idx.rootFileCount(inner));
}

test "with nested folders, an exclusion is judged from the inner one, as a rescan would" {
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();
    try fx.touch("outer/b/inside.txt");
    try fx.touch("outer/other/b/hidden.txt");
    const idx = try fx.open();
    defer idx.close();
    var outer_buf: [std.fs.max_path_bytes]u8 = undefined;
    const outer = try std.fmt.bufPrint(&outer_buf, "{s}/outer", .{fx.root()});
    var inner_buf: [std.fs.max_path_bytes]u8 = undefined;
    const inner = try std.fmt.bufPrint(&inner_buf, "{s}/outer/b", .{fx.root()});
    _ = try idx.indexRoot(outer, null, null);
    _ = try idx.indexRoot(inner, null, null);

    try idx.addExclude("b");
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var hits: [8]Hit = undefined;
    // `outer/b` is a saved folder in its own right, so what is inside it stays.
    try testing.expectEqual(@as(usize, 1), try idx.search(arena.allocator(), "inside.txt", 0, &hits));
    try testing.expectEqual(@as(usize, 0), try idx.search(arena.allocator(), "hidden.txt", 0, &hits));
    try expectRescanChangesNothing(idx);
}

test "removing an exclusion and rescanning for it brings the entries back" {
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();
    try fx.touch("one/cache/a.txt");
    try fx.touch("two/b.txt");
    const idx = try fx.open();
    defer idx.close();
    var one_buf: [std.fs.max_path_bytes]u8 = undefined;
    const one = try std.fmt.bufPrint(&one_buf, "{s}/one", .{fx.root()});
    var two_buf: [std.fs.max_path_bytes]u8 = undefined;
    const two = try std.fmt.bufPrint(&two_buf, "{s}/two", .{fx.root()});
    var cache_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cache = try std.fmt.bufPrint(&cache_buf, "{s}/one/cache", .{fx.root()});
    _ = try idx.indexRoot(one, null, null);
    _ = try idx.indexRoot(two, null, null);

    try idx.addExclude(cache);
    try testing.expectEqual(@as(u64, 0), idx.rootFileCount(one));

    // An absolute path only needs the folder that contains it: `two` is not walked, so a file
    // deleted there is still listed afterwards.
    try fx.tree.dir.deleteFile(testing.io, "two/b.txt");
    try idx.removeExclude(cache);
    try testing.expectEqual(@as(u64, 2), try idx.rescanForPattern(cache, null, null));
    try testing.expectEqual(@as(u64, 2), idx.rootFileCount(one));
    try testing.expectEqual(@as(u64, 1), idx.rootFileCount(two));

    // A name pattern can hide things anywhere, so every folder is walked.
    try idx.addExclude("cache");
    try idx.removeExclude("cache");
    try testing.expectEqual(@as(u64, 2), try idx.rescanForPattern("cache", null, null));
    try testing.expectEqual(@as(u64, 0), idx.rootFileCount(two));
    try testing.expectEqual(@as(u64, 0), try idx.rescanForPattern("/nowhere/near", null, null));
    try testing.expectEqual(@as(u64, 0), try idx.rescanForPattern("", null, null));
}

test "reindexAll rescans every root and skips ones that have vanished" {
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();
    var other: Fixture = undefined;
    try other.init();
    defer other.deinit();
    try fx.touch("one.txt");
    try other.touch("two.txt");
    const idx = try fx.open();
    defer idx.close();
    _ = try idx.indexRoot(fx.root(), null, null);
    _ = try idx.indexRoot(other.root(), null, null);
    try testing.expectEqual(@as(u64, 2), try idx.reindexAll(null, null));

    try idx.addRoot("/definitely/not/a/real/folder");
    try fx.touch("three.txt");
    try testing.expectEqual(@as(u64, 3), try idx.reindexAll(null, null)); // the dead root contributes 0, not an error

    // ...but the failure is reported rather than swallowed.
    var failed: u32 = undefined;
    _ = try idx.reindexAllCounting(null, null, &failed);
    try testing.expectEqual(@as(u32, 1), failed);
    var buf: [error_message_max]u8 = undefined;
    const msg = idx.lastError(&buf);
    try testing.expect(std.mem.startsWith(u8, msg, "/definitely/not/a/real/folder: "));
}

test "lastError starts empty, keeps the latest failure and truncates to the buffer" {
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();
    const idx = try fx.open();
    defer idx.close();
    var buf: [error_message_max]u8 = undefined;
    try testing.expectEqualStrings("", idx.lastError(&buf));

    idx.recordError("first", error.SqliteError);
    idx.recordError("second", error.FileNotFound);
    try testing.expectEqualStrings("second: FileNotFound", idx.lastError(&buf));

    var small: [6]u8 = undefined;
    try testing.expectEqualStrings("second", idx.lastError(&small));
    try testing.expectEqualStrings("", idx.lastError(buf[0..0]));

    const long: [error_message_max * 2]u8 = @splat('p');
    idx.recordError(&long, error.OutOfMemory);
    try testing.expectEqual(@as(usize, error_message_max), idx.lastError(&buf).len);
}

test "rootFileCount does not count a sibling that shares a name prefix" {
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();
    try fx.touch("proj/a.txt");
    try fx.touch("proj/b.txt");
    try fx.touch("proj-old/c.txt");
    const idx = try fx.open();
    defer idx.close();
    _ = try idx.indexRoot(fx.root(), null, null);
    const proj = try std.fmt.allocPrint(testing.allocator, "{s}/proj", .{fx.root()});
    defer testing.allocator.free(proj);
    try testing.expectEqual(@as(u64, 2), idx.rootFileCount(proj));
    try testing.expectEqual(@as(u64, 0), idx.rootFileCount("/no/such/root"));
}

test "removing a root leaves siblings that share a name prefix alone" {
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();
    try fx.touch("proj/a.txt");
    try fx.touch("proj-old/c.txt");
    const idx = try fx.open();
    defer idx.close();
    const proj = try std.fmt.allocPrint(testing.allocator, "{s}/proj", .{fx.root()});
    defer testing.allocator.free(proj);
    const old = try std.fmt.allocPrint(testing.allocator, "{s}/proj-old", .{fx.root()});
    defer testing.allocator.free(old);
    _ = try idx.indexRoot(proj, null, null);
    _ = try idx.indexRoot(old, null, null);

    try idx.removeRoot(proj);
    try testing.expectEqual(@as(u64, 0), idx.rootFileCount(proj));
    try testing.expectEqual(@as(u64, 1), idx.rootFileCount(old));
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var hits: [4]Hit = undefined;
    try testing.expectEqual(@as(usize, 1), try idx.search(arena.allocator(), "c.txt", 0, &hits));
    try testing.expectEqual(@as(usize, 0), try idx.search(arena.allocator(), "a.txt", 0, &hits));
}

test "deleting a file under one root does not disturb another root" {
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();
    var other: Fixture = undefined;
    try other.init();
    defer other.deinit();
    try fx.touch("gone.txt");
    try other.touch("stays.txt");
    const idx = try fx.open();
    defer idx.close();
    _ = try idx.indexRoot(fx.root(), null, null);
    _ = try idx.indexRoot(other.root(), null, null);
    try fx.tree.dir.deleteFile(testing.io, "gone.txt");
    _ = try idx.indexRoot(fx.root(), null, null);
    try testing.expectEqual(@as(u64, 0), idx.rootFileCount(fx.root()));
    try testing.expectEqual(@as(u64, 1), idx.rootFileCount(other.root()));
}

test "symlinks are indexed as entries and never followed" {
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();
    try fx.touch("real/inside.txt");
    // A link back to the root would loop forever if followed.
    try fx.tree.dir.symLink(testing.io, fx.root(), "loop", .{ .is_directory = true });
    const idx = try fx.open();
    defer idx.close();
    const n = try idx.indexRoot(fx.root(), null, null);
    try testing.expectEqual(@as(u64, 3), n); // real, real/inside.txt, loop
}

test "unreadable folders are skipped, not fatal" {
    if (std.c.geteuid() == 0) return error.SkipZigTest; // root ignores permission bits
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();
    try fx.touch("open/a.txt");
    try fx.touch("locked/b.txt");
    var locked_buf: [std.fs.max_path_bytes + 8]u8 = undefined;
    const locked = try std.fmt.bufPrintSentinel(&locked_buf, "{s}/locked", .{fx.root()}, 0);
    const chmod = struct {
        extern "c" fn chmod(path: [*:0]const u8, mode: c_uint) c_int;
    }.chmod;
    try testing.expectEqual(@as(c_int, 0), chmod(locked.ptr, 0));
    defer _ = chmod(locked.ptr, 0o755); // so the fixture can clean up
    const idx = try fx.open();
    defer idx.close();
    const n = try idx.indexRoot(fx.root(), null, null);
    try testing.expect(n >= 2); // open, open/a.txt, locked itself
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var hits: [4]Hit = undefined;
    try testing.expectEqual(@as(usize, 1), try idx.search(arena.allocator(), "a.txt", 0, &hits));
}

test "long and non-ASCII names round-trip" {
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();
    try fx.touch("héllo wörld ✓.txt");
    const long_name = @as([200]u8, @splat('n')) ++ ".txt".*;
    try fx.touch(&long_name);
    const idx = try fx.open();
    defer idx.close();
    _ = try idx.indexRoot(fx.root(), null, null);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var hits: [4]Hit = undefined;
    try testing.expectEqual(@as(usize, 1), try idx.search(arena.allocator(), "wörld", 0, &hits));
    try testing.expect(std.mem.endsWith(u8, hits[0].path, "héllo wörld ✓.txt"));
    try testing.expectEqual(@as(usize, 1), try idx.search(arena.allocator(), "nnnnnnnn.txt", 0, &hits));
}

test "the parallel search path agrees with the single-threaded one" {
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();
    const idx = try fx.open();
    defer idx.close();
    const rows = parallel_threshold + 5_000;
    // Bulk-load rows straight into SQLite: far cheaper than creating that many files.
    var sql_buf: [512]u8 = undefined;
    const sql = try std.fmt.bufPrintSentinel(&sql_buf,
        \\WITH RECURSIVE c(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM c WHERE i < {d})
        \\INSERT INTO files(path, name, ext, size, mtime, is_dir, seen)
        \\SELECT '/bulk/dir' || (i % 97) || '/file' || i || '.txt', 'file' || i || '.txt', 'txt', i, i, 0, 1 FROM c
    , .{rows}, 0);
    try idx.db.exec(sql);
    try idx.reload();
    try testing.expectEqual(@as(u64, rows), idx.fileCount());

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var hits: [max_hits]Hit = undefined;
    const n = try idx.search(arena.allocator(), "file4242.txt", 0, &hits);
    try testing.expect(n >= 1);
    try testing.expect(std.mem.endsWith(u8, hits[0].path, "/file4242.txt"));
    for (hits[1..n], 0..) |h, i| try testing.expect(hits[i].score >= h.score);

    // Reference: rank the same snapshot on one thread and compare.
    const q = fuzzy.Query.parse("file4242.txt");
    var reference: TopK = .{ .k = max_hits };
    scanRange(&idx.snap, &q, .{}, 0, 0, idx.snap.entries.items.len, &reference);
    try testing.expectEqual(reference.n, n);
    for (hits[0..n], reference.buf[0..n]) |h, r| try testing.expectEqual(r.score, h.score);

    // Filters take the same path.
    const filtered = try idx.searchFiltered(arena.allocator(), "file", .{ .min_size = rows - 2 }, 0, &hits);
    try testing.expectEqual(@as(usize, 3), filtered);
}

test "entries with an empty or oversized path are not loaded" {
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();
    const idx = try fx.open();
    defer idx.close();
    try idx.db.exec("INSERT INTO files(path, name, ext, size, mtime, is_dir, seen) VALUES('', '', '', 0, 0, 0, 1)");
    const huge = try testing.allocator.alloc(u8, std.math.maxInt(u16) + 1);
    defer testing.allocator.free(huge);
    @memset(huge, 'x');
    huge[0] = '/';
    const ins = try idx.db.prepare("INSERT INTO files(path, name, ext, size, mtime, is_dir, seen) VALUES(?, 'x', '', 0, 0, 0, 1)");
    defer ins.finalize();
    try ins.bindText(1, huge);
    _ = try ins.step();
    try idx.db.exec("INSERT INTO files(path, name, ext, size, mtime, is_dir, seen) VALUES('/ok', 'ok', '', 0, 0, 0, 1)");
    try idx.reload();
    try testing.expectEqual(@as(u64, 1), idx.fileCount());
}

test "a negative size in the database loads as zero" {
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();
    const idx = try fx.open();
    defer idx.close();
    try idx.db.exec("INSERT INTO files(path, name, ext, size, mtime, is_dir, seen) VALUES('/neg', 'neg', '', -5, 0, 0, 1)");
    try idx.reload();
    try testing.expectEqual(@as(u64, 0), idx.snap.entries.items[0].size);
}

test "the home folder's Library is skipped, other folders named Library are not" {
    const c = struct {
        extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
    };
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();
    try fx.touch("Library/Caches/junk.txt");
    try fx.touch("Documents/Library/keep.txt");
    try fx.touch("notes.txt");

    const old_home: ?[:0]u8 = if (std.c.getenv("HOME")) |h| try testing.allocator.dupeSentinel(u8, std.mem.span(h), 0) else null;
    defer if (old_home) |h| testing.allocator.free(h);
    var home_buf: [std.fs.max_path_bytes + 1]u8 = undefined;
    const home = try std.fmt.bufPrintSentinel(&home_buf, "{s}", .{fx.root()}, 0);
    try testing.expectEqual(@as(c_int, 0), c.setenv("HOME", home.ptr, 1));
    defer if (old_home) |h| {
        _ = c.setenv("HOME", h.ptr, 1);
    };

    const idx = try fx.open();
    defer idx.close();
    _ = try idx.indexRoot(fx.root(), null, null);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var hits: [4]Hit = undefined;
    try testing.expectEqual(@as(usize, 0), try idx.search(arena.allocator(), "junk.txt", 0, &hits));
    try testing.expectEqual(@as(usize, 1), try idx.search(arena.allocator(), "keep.txt", 0, &hits));
    try testing.expectEqual(@as(usize, 1), try idx.search(arena.allocator(), "notes.txt", 0, &hits));
}

test "searches and re-scans can overlap" {
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();
    for (0..20) |i| {
        var name_buf: [32]u8 = undefined;
        try fx.touch(try std.fmt.bufPrint(&name_buf, "dir/file{d}.txt", .{i}));
    }
    const idx = try fx.open();
    defer idx.close();
    _ = try idx.indexRoot(fx.root(), null, null);

    const Searcher = struct {
        fn loop(index: *Index, misses: *std.atomic.Value(u32)) void {
            var arena: std.heap.ArenaAllocator = .init(testing.allocator);
            defer arena.deinit();
            var hits: [8]Hit = undefined;
            for (0..200) |_| {
                _ = arena.reset(.retain_capacity);
                const n = index.search(arena.allocator(), "file", 0, &hits) catch {
                    _ = misses.fetchAdd(1, .monotonic);
                    continue;
                };
                // A snapshot swap must never expose a half-built snapshot.
                if (n != 8) _ = misses.fetchAdd(1, .monotonic);
            }
        }
    };
    var misses: std.atomic.Value(u32) = .init(0);
    const t = try std.Thread.spawn(.{}, Searcher.loop, .{ idx, &misses });
    for (0..10) |_| _ = try idx.indexRoot(fx.root(), null, null);
    t.join();
    try testing.expectEqual(@as(u32, 0), misses.load(.monotonic));
}

fn readLog(fx: *const Fixture) ![]u8 {
    return fx.db_dir.dir.readFileAlloc(testing.io, "seek.log", testing.allocator, .limited(4 * log_max_bytes));
}

test "the log sits next to the database and records opens, scans and failures" {
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();
    try fx.touch("a.txt");
    const idx = try fx.open();
    defer idx.close();
    try testing.expect(std.mem.endsWith(u8, idx.logPath(), "/seek.log"));
    try testing.expectEqualStrings(std.fs.path.dirname(fx.dbPath()).?, std.fs.path.dirname(idx.logPath()).?);

    _ = try idx.indexRoot(fx.root(), null, null);
    idx.recordError("add folder", error.FileNotFound);

    const text = try readLog(&fx);
    defer testing.allocator.free(text);
    try testing.expect(std.mem.indexOf(u8, text, " info opened index with 0 entries (SQLite ") != null);
    try testing.expect(std.mem.indexOf(u8, text, " info scanned ") != null);
    try testing.expect(std.mem.indexOf(u8, text, " error add folder: FileNotFound\n") != null);
    // "2026-10-15T01:02:03Z level ..." — a UTC timestamp leads every line.
    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, text, "\n"), '\n');
    while (lines.next()) |line| {
        try testing.expect(line.len > 21 and line[4] == '-' and line[10] == 'T' and line[19] == 'Z' and line[20] == ' ');
    }
}

test "an in-memory database has no log and logging is harmless" {
    const idx = try Index.open(testing.allocator, testing.io, ":memory:");
    defer idx.close();
    try testing.expectEqualStrings("", idx.logPath());
    idx.recordError("nowhere to write", error.OutOfMemory);
    idx.logf("info", "still fine {d}", .{1});
}

test "the log rotates instead of growing without bound" {
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();
    const idx = try fx.open();
    defer idx.close();
    const filler: [200]u8 = @splat('x');
    for (0..log_max_bytes / 100) |_| idx.logf("info", "{s}", .{&filler});
    idx.logf("info", "after rotation", .{});

    const old = try fx.db_dir.dir.readFileAlloc(testing.io, "seek.log.1", testing.allocator, .limited(4 * log_max_bytes));
    defer testing.allocator.free(old);
    try testing.expect(old.len > log_max_bytes);
    const current = try readLog(&fx);
    defer testing.allocator.free(current);
    try testing.expect(current.len < log_max_bytes);
    try testing.expect(std.mem.indexOf(u8, current, "after rotation") != null);
}

// ---------------------------------------------------------------- schema versions and recovery

/// Opens the fixture's database file directly, bypassing `Index.open`.
fn rawDb(fx: *const Fixture) !sqlite.Db {
    return sqlite.Db.open(fx.dbPath());
}

fn dbDirHas(fx: *const Fixture, name: []const u8) bool {
    return if (fx.db_dir.dir.statFile(testing.io, name, .{})) |_| true else |_| false;
}

fn expectLastError(idx: *Index, expected: []const u8) !void {
    var buf: [error_message_max]u8 = undefined;
    try testing.expectEqualStrings(expected, idx.lastError(&buf));
}

/// Saves a folder and an exclusion so a test can check that recovery carries them over.
fn addSettings(idx: *Index, fx: *const Fixture) !void {
    try idx.addRoot(fx.root());
    try idx.addExclude("*.log");
}

fn expectSettingsKept(idx: *Index, fx: *const Fixture) !void {
    const r = try idx.roots(testing.allocator);
    defer freeRoots(testing.allocator, r);
    try testing.expectEqual(@as(usize, 1), r.len);
    try testing.expectEqualStrings(fx.root(), r[0]);
    const ex = try idx.excludes(testing.allocator);
    defer freeRoots(testing.allocator, ex);
    try testing.expectEqual(@as(usize, 1), ex.len);
    try testing.expectEqualStrings("*.log", ex[0]);
}

test "a new database is stamped with the current schema version" {
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();
    const idx = try fx.open();
    defer idx.close();
    try testing.expectEqual(@as(i64, schema_version), try idx.db.userVersion());
    try expectLastError(idx, "");
}

test "a database from before versioning keeps its data and is stamped" {
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();
    {
        const db = try rawDb(&fx);
        defer db.close();
        try db.exec(migrations[0]);
        try db.exec("INSERT INTO files(path, name, ext, size, mtime, is_dir, seen) VALUES('/old/a.txt', 'a.txt', 'txt', 3, 0, 0, 1)");
        try db.exec("INSERT INTO roots(path) VALUES('/old')");
        try testing.expectEqual(@as(i64, 0), try db.userVersion());
    }
    const idx = try fx.open();
    defer idx.close();
    try testing.expectEqual(@as(u64, 1), idx.fileCount());
    try testing.expectEqual(@as(i64, schema_version), try idx.db.userVersion());
    const r = try idx.roots(testing.allocator);
    defer freeRoots(testing.allocator, r);
    try testing.expectEqual(@as(usize, 1), r.len);
    try expectLastError(idx, "");
    try testing.expect(!dbDirHas(&fx, "seek.db.corrupt"));
    const log = try readLog(&fx);
    defer testing.allocator.free(log);
    try testing.expect(std.mem.indexOf(u8, log, " info database schema 0 -> ") != null);
}

test "migrate runs only the pending steps, in order, and is a no-op when current" {
    const db = try sqlite.Db.open(":memory:");
    defer db.close();
    // Re-running step 1 would fail (no IF NOT EXISTS), so this also proves it is skipped.
    const steps = [_][:0]const u8{ "CREATE TABLE a(x)", "CREATE TABLE b(y); INSERT INTO b SELECT x FROM a" };
    try db.exec(steps[0]);
    try db.setUserVersion(1);
    try testing.expectEqual(@as(i64, 1), try migrate(db, &steps));
    try testing.expectEqual(@as(i64, 2), try db.userVersion());
    try testing.expectEqual(@as(i64, 2), try migrate(db, &steps));
    try db.exec("SELECT y FROM b");
}

test "a failing migration step rolls back every step and keeps the version" {
    const db = try sqlite.Db.open(":memory:");
    defer db.close();
    const steps = [_][:0]const u8{ "CREATE TABLE a(x)", "NOT SQL" };
    try testing.expectError(error.SqliteError, migrate(db, &steps));
    try testing.expectEqual(@as(i64, 0), try db.userVersion());
    try testing.expectError(error.SqliteError, db.exec("SELECT x FROM a"));
}

test "migrate refuses a version it doesn't know and changes nothing" {
    const db = try sqlite.Db.open(":memory:");
    defer db.close();
    try db.setUserVersion(schema_version + 1);
    try testing.expectError(error.UnsupportedSchemaVersion, migrate(db, &migrations));
    try testing.expectEqual(@as(i64, schema_version + 1), try db.userVersion());
    try db.setUserVersion(-1);
    try testing.expectError(error.UnsupportedSchemaVersion, migrate(db, &migrations));
}

test "a database from a newer Seek is refused and left exactly as it was" {
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();
    {
        const idx = try fx.open();
        defer idx.close();
        try addSettings(idx, &fx);
        try idx.db.setUserVersion(schema_version + 1);
    }
    // A downgrade must not destroy the newer Seek's data (it may even still be running).
    try testing.expectError(error.UnsupportedSchemaVersion, fx.open());
    try testing.expect(!dbDirHas(&fx, "seek.db.corrupt"));
    const db = try rawDb(&fx);
    defer db.close();
    try testing.expectEqual(@as(i64, schema_version + 1), try db.userVersion());
    const r = try textColumn(testing.allocator, db, "SELECT path FROM roots");
    defer freeRoots(testing.allocator, r);
    try testing.expectEqual(@as(usize, 1), r.len);
}

test "opening a current database doesn't wait for another connection's write" {
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();
    try fx.touch("a.txt");
    const writer = try fx.open();
    defer writer.close();
    _ = try writer.indexRoot(fx.root(), null, null);
    try writer.db.exec("BEGIN IMMEDIATE"); // as a scan does, for many seconds on a slow disk
    defer writer.db.exec("ROLLBACK") catch {};

    const t0 = Io.Timestamp.now(testing.io, .awake);
    const reader = try fx.open();
    defer reader.close();
    try testing.expectEqual(@as(u64, 1), reader.fileCount());
    const waited_ms = @divTrunc(Io.Timestamp.now(testing.io, .awake).nanoseconds - t0.nanoseconds, std.time.ns_per_ms);
    try testing.expect(waited_ms < 1000); // the busy timeout is 5 s
}

test "a damaged database another process has open is left alone" {
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();
    const junk: [8192]u8 = @splat('j');
    try fx.db_dir.dir.writeFile(testing.io, .{ .sub_path = "seek.db", .data = &junk });

    // A child process holds a read lock on SQLite's shared-lock bytes, exactly as an open
    // connection in another process (say, the app while the CLI runs) does.
    var to_child: [2]c_int = undefined;
    var to_parent: [2]c_int = undefined;
    try testing.expectEqual(@as(c_int, 0), std.c.pipe(&to_child));
    try testing.expectEqual(@as(c_int, 0), std.c.pipe(&to_parent));
    const pid = std.c.fork();
    try testing.expect(pid >= 0);
    if (pid == 0) {
        const fd = std.c.open(fx.dbPath().ptr, .{ .ACCMODE = .RDWR });
        var fl = std.mem.zeroes(std.c.Flock);
        fl.type = std.c.F.RDLCK;
        fl.whence = std.c.SEEK.SET;
        fl.start = sqlite_shared_first;
        fl.len = sqlite_shared_size;
        const ok: u8 = if (fd >= 0 and std.c.fcntl(fd, std.c.F.SETLK, &fl) == 0) 1 else 0;
        _ = std.c.write(to_parent[1], @ptrCast(&ok), 1);
        var b: u8 = 0;
        _ = std.c.read(to_child[0], @ptrCast(&b), 1); // hold the lock until the parent is done
        std.c._exit(0);
    }
    var ok: u8 = 0;
    _ = std.c.read(to_parent[0], @ptrCast(&ok), 1);
    const result = fx.open();
    _ = std.c.write(to_child[1], "x", 1);
    var status: c_int = 0;
    _ = std.c.waitpid(pid, &status, 0);
    for (to_child ++ to_parent) |fd| _ = std.c.close(fd);

    try testing.expectEqual(@as(u8, 1), ok);
    try testing.expectError(error.DatabaseCorrupt, result);
    try testing.expect(!dbDirHas(&fx, "seek.db.corrupt"));
    const still = try fx.db_dir.dir.readFileAlloc(testing.io, "seek.db", testing.allocator, .limited(junk.len + 1));
    defer testing.allocator.free(still);
    try testing.expectEqualSlices(u8, &junk, still);
}

test "a second recovery doesn't replay the first one's leftover log" {
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();
    try fx.db_dir.dir.writeFile(testing.io, .{ .sub_path = "seek.db.corrupt-wal", .data = "first recovery's log" });
    try fx.db_dir.dir.writeFile(testing.io, .{ .sub_path = "seek.db.corrupt-shm", .data = "first recovery's index" });
    const junk: [8192]u8 = @splat('j');
    try fx.db_dir.dir.writeFile(testing.io, .{ .sub_path = "seek.db", .data = &junk });

    const idx = try fx.open();
    defer idx.close();
    try testing.expect(dbDirHas(&fx, "seek.db.corrupt"));
    for ([_][]const u8{ "seek.db.corrupt-wal", "seek.db.corrupt-shm" }) |name| {
        if (fx.db_dir.dir.readFileAlloc(testing.io, name, testing.allocator, .limited(1 << 20))) |data| {
            defer testing.allocator.free(data);
            try testing.expect(std.mem.indexOf(u8, data, "first recovery") == null);
        } else |_| {}
    }
}

test "a file that isn't a database is set aside and replaced" {
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();
    const junk: [8192]u8 = @splat('j');
    try fx.db_dir.dir.writeFile(testing.io, .{ .sub_path = "seek.db", .data = &junk });
    try fx.db_dir.dir.writeFile(testing.io, .{ .sub_path = "seek.db-wal", .data = "stale log" });

    const idx = try fx.open();
    defer idx.close();
    try testing.expectEqual(@as(u64, 0), idx.fileCount());
    try testing.expectEqual(@as(i64, schema_version), try idx.db.userVersion());
    try expectLastError(idx, "the index database was damaged and has been replaced: DatabaseCorrupt");
    const kept = try fx.db_dir.dir.readFileAlloc(testing.io, "seek.db.corrupt", testing.allocator, .limited(junk.len + 1));
    defer testing.allocator.free(kept);
    try testing.expectEqualSlices(u8, &junk, kept);
    // The stale log is gone (SQLite drops a log it can't use) and didn't leak into the new database.
    if (fx.db_dir.dir.readFileAlloc(testing.io, "seek.db-wal", testing.allocator, .limited(1 << 20))) |wal| {
        defer testing.allocator.free(wal);
        try testing.expect(std.mem.indexOf(u8, wal, "stale log") == null);
    } else |_| {}

    // The replacement works normally and survives a reopen.
    try fx.touch("a.txt");
    _ = try idx.indexRoot(fx.root(), null, null);
    const log = try readLog(&fx);
    defer testing.allocator.free(log);
    try testing.expect(std.mem.indexOf(u8, log, " warn moved the damaged database to ") != null);
    try testing.expect(std.mem.indexOf(u8, log, " error the index database was damaged") != null);
}

test "damage in the files table is recovered, keeping folders and exclusions" {
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();
    for (0..50) |i| {
        var name_buf: [32]u8 = undefined;
        try fx.touch(try std.fmt.bufPrint(&name_buf, "file{d}.txt", .{i}));
    }
    {
        const idx = try fx.open();
        defer idx.close();
        try addSettings(idx, &fx);
        _ = try idx.indexRoot(fx.root(), null, null);
    } // closing the last connection folds the write-ahead log into seek.db

    // Overwrite the files table's root page; the roots and excludes pages stay intact.
    const page_size: usize, const root_page: usize = blk: {
        const db = try rawDb(&fx);
        defer db.close();
        const st = try db.prepare("SELECT (SELECT page_size FROM pragma_page_size), rootpage FROM sqlite_schema WHERE name = 'files'");
        defer st.finalize();
        try testing.expect(try st.step());
        break :blk .{ @intCast(st.int(0)), @intCast(st.int(1)) };
    };
    const bytes = try fx.db_dir.dir.readFileAlloc(testing.io, "seek.db", testing.allocator, .unlimited);
    defer testing.allocator.free(bytes);
    @memset(bytes[(root_page - 1) * page_size ..][0..page_size], 0xff);
    try fx.db_dir.dir.writeFile(testing.io, .{ .sub_path = "seek.db", .data = bytes });

    const idx = try fx.open();
    defer idx.close();
    try testing.expect(dbDirHas(&fx, "seek.db.corrupt"));
    try expectSettingsKept(idx, &fx);
    try expectLastError(idx, "the index database was damaged and has been replaced: DatabaseCorrupt");
    // The saved folder is still known, so the next rescan refills the index.
    try testing.expectEqual(@as(u64, 0), idx.fileCount());
    try testing.expectEqual(@as(u64, 50), try idx.reindexAll(null, null));
}

test "an unreadable in-memory or missing database is an error, not a recovery" {
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();
    const idx = try Index.open(testing.allocator, testing.io, ":memory:");
    defer idx.close();
    try testing.expectError(error.DatabaseCorrupt, idx.recover(":memory:"));
    try testing.expectError(error.DatabaseCorrupt, idx.recover(fx.dbPath()));
    try testing.expect(!dbDirHas(&fx, "seek.db.corrupt"));
}

// ---------------------------------------------------------------- duplicate tests

fn setMtime(fx: *Fixture, path: []const u8, secs: i64) !void {
    const f = try fx.tree.dir.openFile(testing.io, path, .{ .mode = .read_write });
    defer f.close(testing.io);
    try f.setTimestamps(testing.io, .{ .modify_timestamp = .{ .new = .fromNanoseconds(secs * std.time.ns_per_s) } });
}

const DupCounter = struct {
    calls: u64 = 0,
    cancel_after: u64 = std.math.maxInt(u64),

    fn cb(ctx: ?*anyopaque, done: u64, total: u64) callconv(.c) c_int {
        _ = total;
        const self: *DupCounter = @ptrCast(@alignCast(ctx.?));
        self.calls += 1;
        return @intFromBool(done >= self.cancel_after);
    }
};

fn hashRows(idx: *Index) !i64 {
    const st = try idx.db.prepare("SELECT COUNT(*) FROM hashes");
    defer st.finalize();
    _ = try st.step();
    return st.int(0);
}

test "findDuplicates groups identical content, biggest saving first, oldest copy first" {
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();
    const big_a: [1000]u8 = @splat('A');
    const big_b: [1000]u8 = @splat('B');
    try fx.write("a/one.txt", "hello");
    try fx.write("b/two.txt", "hello");
    try fx.write("c/three.txt", "world"); // same size as the others, different content
    try fx.write("d/big1.bin", &big_a);
    try fx.write("e/big2.bin", &big_a);
    try fx.write("e/big3.bin", &big_a);
    try fx.write("f/big4.bin", &big_b);
    try fx.write("g/only.txt", "unique size");
    try fx.touch("h/empty1");
    try fx.touch("h/empty2");
    try setMtime(&fx, "a/one.txt", 2_000_000);
    try setMtime(&fx, "b/two.txt", 1_000_000);

    const idx = try fx.open();
    defer idx.close();
    _ = try idx.indexRoot(fx.root(), null, null);
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const groups = try idx.findDuplicates(arena_state.allocator(), 0, null, null);

    try testing.expectEqual(@as(usize, 2), groups.len);
    try testing.expectEqual(@as(u64, 1000), groups[0].size);
    try testing.expectEqual(@as(usize, 3), groups[0].files.len);
    try testing.expectEqual(@as(u64, 2000), groups[0].reclaimable());
    try testing.expectEqual(@as(u64, 5), groups[1].size);
    try testing.expectEqual(@as(usize, 2), groups[1].files.len);
    try testing.expect(std.mem.endsWith(u8, groups[1].files[0].path, "b/two.txt")); // older first
    try testing.expect(std.mem.endsWith(u8, groups[1].files[1].path, "a/one.txt"));
    try testing.expectEqual(@as(i64, 1_000_000), groups[1].files[0].mtime);
    for (groups) |g| for (g.files) |f| {
        try testing.expect(std.mem.indexOf(u8, f.path, "empty") == null);
        try testing.expect(std.mem.indexOf(u8, f.path, "three") == null);
    };
}

test "findDuplicates honours min_size and skips symlinks" {
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();
    try fx.write("a.txt", "hello");
    try fx.write("b.txt", "hello");
    const big: [100]u8 = @splat('X');
    try fx.write("big1", &big);
    try fx.write("big2", &big);
    // A dangling link whose target path is 5 bytes: indexed with size 5, like the files above.
    try fx.tree.dir.symLink(testing.io, "abcde", "link", .{});
    const idx = try fx.open();
    defer idx.close();
    _ = try idx.indexRoot(fx.root(), null, null);
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();

    const all = try idx.findDuplicates(arena_state.allocator(), 0, null, null);
    try testing.expectEqual(@as(usize, 2), all.len);
    for (all) |g| for (g.files) |f| try testing.expect(!std.mem.endsWith(u8, f.path, "link"));

    const large = try idx.findDuplicates(arena_state.allocator(), 50, null, null);
    try testing.expectEqual(@as(usize, 1), large.len);
    try testing.expectEqual(@as(u64, 100), large[0].size);
}

test "unchanged files are served from the hash cache, edited ones are rehashed" {
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();
    try fx.write("a.txt", "hello");
    try fx.write("b.txt", "hello");
    const idx = try fx.open();
    defer idx.close();
    _ = try idx.indexRoot(fx.root(), null, null);
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var counter: DupCounter = .{};
    try testing.expectEqual(@as(usize, 1), (try idx.findDuplicates(arena, 0, DupCounter.cb, &counter)).len);
    try testing.expectEqual(@as(u64, 2), counter.calls); // both files read
    try testing.expectEqual(@as(i64, 2), try hashRows(idx));

    counter = .{};
    try testing.expectEqual(@as(usize, 1), (try idx.findDuplicates(arena, 0, DupCounter.cb, &counter)).len);
    try testing.expectEqual(@as(u64, 0), counter.calls); // nothing read

    // Same size, different content, new mtime: no longer a duplicate, and only b.txt is read again.
    try fx.write("b.txt", "world");
    try setMtime(&fx, "b.txt", 3_000_000);
    counter = .{};
    try testing.expectEqual(@as(usize, 0), (try idx.findDuplicates(arena, 0, DupCounter.cb, &counter)).len);
    try testing.expectEqual(@as(u64, 1), counter.calls);
}

test "a canceled run keeps the hashes it computed" {
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();
    inline for (.{ "a", "b", "c", "d" }) |n| try fx.write(n, "same!");
    const idx = try fx.open();
    defer idx.close();
    _ = try idx.indexRoot(fx.root(), null, null);
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var counter: DupCounter = .{ .cancel_after = 2 };
    try testing.expectError(error.Canceled, idx.findDuplicates(arena, 0, DupCounter.cb, &counter));
    try testing.expectEqual(@as(i64, 2), try hashRows(idx));

    counter = .{};
    const groups = try idx.findDuplicates(arena, 0, DupCounter.cb, &counter);
    try testing.expectEqual(@as(usize, 1), groups.len);
    try testing.expectEqual(@as(usize, 4), groups[0].files.len);
    try testing.expectEqual(@as(u64, 2), counter.calls); // only the two not yet hashed
}

test "hashes of files that left the index are forgotten" {
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();
    try fx.write("a.txt", "hello");
    try fx.write("b.txt", "hello");
    try fx.write("c.txt", "hello");
    const idx = try fx.open();
    defer idx.close();
    _ = try idx.indexRoot(fx.root(), null, null);
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    try testing.expectEqual(@as(usize, 3), (try idx.findDuplicates(arena_state.allocator(), 0, null, null))[0].files.len);
    try testing.expectEqual(@as(i64, 3), try hashRows(idx));

    try fx.tree.dir.deleteFile(testing.io, "c.txt");
    _ = try idx.indexRoot(fx.root(), null, null);
    try testing.expectEqual(@as(usize, 2), (try idx.findDuplicates(arena_state.allocator(), 0, null, null))[0].files.len);
    try testing.expectEqual(@as(i64, 2), try hashRows(idx));
}

test "findDuplicates on an empty index finds nothing" {
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();
    const idx = try fx.open();
    defer idx.close();
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    try testing.expectEqual(@as(usize, 0), (try idx.findDuplicates(arena_state.allocator(), 0, null, null)).len);
}

test "hard links to one file are not duplicates of each other" {
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();
    try fx.write("a.txt", "hello");
    try fx.write("copy.txt", "hello");
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const target = try std.fmt.bufPrint(&buf, "{s}/a.txt", .{fx.root()});
    try Io.Dir.hardLink(.cwd(), target, fx.tree.dir, "link.txt", testing.io, .{});
    const idx = try fx.open();
    defer idx.close();
    _ = try idx.indexRoot(fx.root(), null, null);
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const groups = try idx.findDuplicates(arena_state.allocator(), 0, null, null);
    try testing.expectEqual(@as(usize, 1), groups.len);
    try testing.expectEqual(@as(usize, 2), groups[0].files.len); // a.txt/link.txt count once, plus copy.txt
}
