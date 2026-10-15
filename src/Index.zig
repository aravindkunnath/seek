//! The Seek index: SQLite is the source of truth; a compact in-memory snapshot
//! of every path serves as-you-type filename search.
//!
//! Thread safety: `search` and `indexRoot` may run on different threads.
//! Indexing is serialized by `db_mutex`; the snapshot swap is guarded by `mem_mutex`.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const sqlite = @import("sqlite.zig");
const fuzzy = @import("fuzzy.zig");

const Index = @This();

gpa: Allocator,
io: Io,
db: sqlite.Db,
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
    buf: []u8 = &.{},
    entries: []Entry = &.{},

    fn deinit(s: *Snapshot, gpa: Allocator) void {
        gpa.free(s.buf);
        gpa.free(s.entries);
        s.* = .{};
    }

    pub fn path(s: *const Snapshot, e: Entry) []const u8 {
        return s.buf[e.off..][0..e.len];
    }
};

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
};

/// The `user_version` this build writes and understands.
pub const schema_version: i32 = migrations.len;

/// Brings `db` up to `steps.len`, all steps in one transaction, and returns the version it
/// started at. A version this build doesn't know (newer, or negative) is `UnsupportedSchemaVersion`
/// and leaves the database untouched; so does a failing step.
fn migrate(db: sqlite.Db, steps: []const [:0]const u8) !i64 {
    // IMMEDIATE takes the write lock up front, so two processes opening at once can't both migrate.
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

/// Opens or creates the index at `db_path` (or ":memory:"). A database that is damaged, isn't a
/// database, or comes from a newer Seek is moved aside (`seek.db.corrupt` / `seek.db.newer`) and
/// replaced by an empty one that keeps whatever folders and exclusions could still be read; the
/// next scan refills it. That is logged and reported by `lastError`.
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
        error.DatabaseCorrupt, error.UnsupportedSchemaVersion => try self.recover(db_path, err),
        else => |e| return e,
    };
    self.logf("info", "opened index with {d} entries", .{self.fileCount()});
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

/// Sets an unusable database aside and opens a fresh one in its place, carrying over the folders
/// and exclusions that can still be read. Returns `cause` when there is no file to set aside.
fn recover(self: *Index, db_path: [:0]const u8, cause: anyerror) !void {
    if (std.mem.eql(u8, db_path, ":memory:")) return cause;
    const gpa = self.gpa;
    const suffix = if (cause == error.UnsupportedSchemaVersion) "newer" else "corrupt";
    const aside = try std.fmt.allocPrintSentinel(gpa, "{s}.{s}", .{ db_path, suffix }, 0);
    defer gpa.free(aside);
    if (std.c.rename(db_path.ptr, aside.ptr) != 0) return cause; // missing or can't be moved: give up
    // The write-ahead log belongs to the old file; a fresh database must not start with it.
    // (-shm is only a cache of the log's index.)
    const wal = try std.fmt.allocPrintSentinel(gpa, "{s}-wal", .{db_path}, 0);
    defer gpa.free(wal);
    const aside_wal = try std.fmt.allocPrintSentinel(gpa, "{s}-wal", .{aside}, 0);
    defer gpa.free(aside_wal);
    const shm = try std.fmt.allocPrintSentinel(gpa, "{s}-shm", .{db_path}, 0);
    defer gpa.free(shm);
    _ = std.c.rename(wal.ptr, aside_wal.ptr); // usually absent
    _ = std.c.unlink(shm.ptr);

    const kept_roots = salvage(gpa, aside, "SELECT path FROM roots ORDER BY path");
    defer freeRoots(gpa, kept_roots);
    const kept_excludes = salvage(gpa, aside, "SELECT pattern FROM excludes ORDER BY pattern");
    defer freeRoots(gpa, kept_excludes);

    try self.openDb(db_path);
    errdefer {
        self.snap.deinit(gpa);
        self.db.close();
    }
    for (kept_roots) |r| try self.addRoot(r);
    for (kept_excludes) |p| try self.addExclude(p);
    self.logf("warn", "moved the old database to {s}; kept {d} folder(s) and {d} exclusion(s)", .{ aside, kept_roots.len, kept_excludes.len });
    self.recordError("the index database was unusable and has been replaced", cause);
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
    for (snap.entries) |e| {
        const p = snap.path(e);
        if (std.mem.eql(u8, root, "/") or (p.len > root.len and p[root.len] == '/' and std.mem.startsWith(u8, p, root))) n += 1;
    }
    return n;
}

/// User exclusions: a name or `*` pattern matched against every file and folder name
/// (`*.log`, `build`), or an absolute path that skips that folder.
pub fn addExclude(self: *Index, pattern: []const u8) !void {
    if (pattern.len == 0) return;
    self.db_mutex.lockUncancelable(self.io);
    defer self.db_mutex.unlock(self.io);
    const st = try self.db.prepare("INSERT OR IGNORE INTO excludes(pattern) VALUES(?)");
    defer st.finalize();
    try st.bindText(1, if (pattern[0] == '/') trimSlash(pattern) else pattern);
    _ = try st.step();
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

/// Scans `root` (absolute) into the database, removes rows for files that no
/// longer exist under it, then refreshes the in-memory snapshot.
/// Returns the number of entries seen.
pub fn indexRoot(self: *Index, root_in: []const u8, progress: ?ProgressFn, ctx: ?*anyopaque) !u64 {
    const io = self.io;
    const root = trimSlash(root_in);
    const home = if (std.c.getenv("HOME")) |h| trimSlash(std.mem.span(h)) else "";
    const root_is_home = home.len > 0 and std.mem.eql(u8, root, home);

    var dir = try Io.Dir.openDirAbsolute(io, root, .{ .iterate = true });
    defer dir.close(io);

    self.db_mutex.lockUncancelable(io);
    defer self.db_mutex.unlock(io);
    const db = self.db;

    const user_ex = try self.excludesLocked(self.gpa);
    defer freeRoots(self.gpa, user_ex);

    const scan_id: i64 = blk: {
        const st = try db.prepare("SELECT COALESCE(MAX(seen), 0) + 1 FROM files");
        defer st.finalize();
        _ = try st.step();
        break :blk st.int(0);
    };

    const upsert = try db.prepare(
        \\INSERT INTO files(path, name, ext, size, mtime, is_dir, seen) VALUES(?, ?, ?, ?, ?, ?, ?)
        \\ON CONFLICT(path) DO UPDATE SET size=excluded.size, mtime=excluded.mtime,
        \\  is_dir=excluded.is_dir, seen=excluded.seen
    );
    defer upsert.finalize();

    try db.exec("BEGIN");
    var committed = false;
    defer if (!committed) db.exec("ROLLBACK") catch {};

    var walker = try dir.walkSelectively(self.gpa);
    defer walker.deinit();

    var full: std.ArrayList(u8) = .empty;
    defer full.deinit(self.gpa);
    var ext_buf: [32]u8 = undefined;
    var count: u64 = 0;

    while (true) {
        const entry = walker.next(io) catch continue orelse break; // unreadable dirs are skipped
        const name = entry.basename;
        if (isExcluded(name)) continue;
        full.clearRetainingCapacity();
        try full.appendSlice(self.gpa, if (std.mem.eql(u8, root, "/")) "" else root);
        try full.append(self.gpa, '/');
        try full.appendSlice(self.gpa, entry.path);
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

        const ext_raw = extOf(name);
        const ext = std.ascii.lowerString(&ext_buf, ext_raw[0..@min(ext_raw.len, ext_buf.len)]);

        upsert.reset();
        try upsert.bindText(1, full.items);
        try upsert.bindText(2, name);
        try upsert.bindText(3, ext);
        try upsert.bindInt(4, @intCast(size));
        try upsert.bindInt(5, mtime);
        try upsert.bindInt(6, @intFromBool(is_dir));
        try upsert.bindInt(7, scan_id);
        _ = try upsert.step();

        count += 1;
        if (count % 20_000 == 0) {
            try db.exec("COMMIT");
            try db.exec("BEGIN");
        }
        if (progress) |cb| if (count % 5_000 == 0) cb(ctx, count);
    }

    // Drop rows under this root that weren't seen in this scan (deleted files).
    // Range [root/, root0) covers every path below root ('0' follows '/').
    {
        const lo = try std.fmt.allocPrint(self.gpa, "{s}/", .{root});
        defer self.gpa.free(lo);
        const hi = try std.fmt.allocPrint(self.gpa, "{s}0", .{root});
        defer self.gpa.free(hi);
        const del = try db.prepare("DELETE FROM files WHERE path >= ? AND path < ? AND seen <> ?");
        defer del.finalize();
        try del.bindText(1, lo);
        try del.bindText(2, hi);
        try del.bindInt(3, scan_id);
        _ = try del.step();
    }
    {
        const st = try db.prepare("INSERT OR IGNORE INTO roots(path) VALUES(?)");
        defer st.finalize();
        try st.bindText(1, root);
        _ = try st.step();
    }
    try db.exec("COMMIT");
    committed = true;
    if (progress) |cb| cb(ctx, count);

    try self.reloadLocked();
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
    self.db_mutex.lockUncancelable(self.io);
    defer self.db_mutex.unlock(self.io);
    try self.reloadLocked();
}

/// Builds a fresh snapshot from SQLite and swaps it in. Caller holds db_mutex.
fn reloadLocked(self: *Index) !void {
    const gpa = self.gpa;
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(gpa);
    var entries: std.ArrayList(Entry) = .empty;
    errdefer entries.deinit(gpa);

    const st = try self.db.prepare("SELECT path, size, mtime, is_dir FROM files");
    defer st.finalize();
    while (try st.step()) {
        const p = st.text(0);
        if (p.len == 0 or p.len > std.math.maxInt(u16)) continue;
        const off = buf.items.len;
        if (off + p.len + 1 > std.math.maxInt(u32)) break; // >4 GB of paths: stop growing
        try buf.appendSlice(gpa, p);
        try buf.append(gpa, 0);
        const name_off: u32 = if (std.mem.findScalarLast(u8, p, '/')) |s| @intCast(s + 1) else 0;
        try entries.append(gpa, .{
            .off = @intCast(off),
            .len = @intCast(p.len),
            .name_off = name_off,
            .path_mask = fuzzy.charMask(p),
            .name_mask = fuzzy.charMask(p[name_off..]),
            .is_dir = st.int(3) != 0,
            .size = @intCast(@max(st.int(1), 0)),
            .mtime = st.int(2),
        });
    }

    var fresh: Snapshot = .{
        .buf = try buf.toOwnedSlice(gpa),
        .entries = try entries.toOwnedSlice(gpa),
    };
    self.mem_mutex.lockUncancelable(self.io);
    std.mem.swap(Snapshot, &self.snap, &fresh);
    self.mem_mutex.unlock(self.io);
    fresh.deinit(gpa);
}

pub fn fileCount(self: *Index) u64 {
    self.mem_mutex.lockUncancelable(self.io);
    defer self.mem_mutex.unlock(self.io);
    return self.snap.entries.len;
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
    for (snap.entries[start..end], start..) |e, i| {
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
    const total = snap.entries.len;

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
        const e = snap.entries[r.idx];
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
    for (snap.entries) |e| {
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
    scanRange(&idx.snap, &q, .{}, 0, 0, idx.snap.entries.len, &reference);
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
    try testing.expectEqual(@as(u64, 0), idx.snap.entries[0].size);
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
    try testing.expect(std.mem.indexOf(u8, text, " info opened index with 0 entries\n") != null);
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

test "a database from a newer Seek is set aside, keeping folders and exclusions" {
    var fx: Fixture = undefined;
    try fx.init();
    defer fx.deinit();
    {
        const idx = try fx.open();
        defer idx.close();
        try addSettings(idx, &fx);
        try idx.db.setUserVersion(schema_version + 1);
    }
    const idx = try fx.open();
    defer idx.close();
    try testing.expect(dbDirHas(&fx, "seek.db.newer"));
    try testing.expectEqual(@as(i64, schema_version), try idx.db.userVersion());
    try expectSettingsKept(idx, &fx);
    try expectLastError(idx, "the index database was unusable and has been replaced: UnsupportedSchemaVersion");
    // The newer file is kept as it was, for a later upgrade or a bug report.
    var buf: [std.fs.max_path_bytes + 32]u8 = undefined;
    const old = try sqlite.Db.open(try std.fmt.bufPrintSentinel(&buf, "{s}.newer", .{fx.dbPath()}, 0));
    defer old.close();
    try testing.expectEqual(@as(i64, schema_version + 1), try old.userVersion());
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
    try expectLastError(idx, "the index database was unusable and has been replaced: DatabaseCorrupt");
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
    try testing.expect(std.mem.indexOf(u8, log, " warn moved the old database to ") != null);
    try testing.expect(std.mem.indexOf(u8, log, " error the index database was unusable") != null);
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
    try expectLastError(idx, "the index database was unusable and has been replaced: DatabaseCorrupt");
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
    try testing.expectError(error.DatabaseCorrupt, idx.recover(":memory:", error.DatabaseCorrupt));
    try testing.expectError(error.DatabaseCorrupt, idx.recover(fx.dbPath(), error.DatabaseCorrupt));
    try testing.expect(!dbDirHas(&fx, "seek.db.corrupt"));
}
