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

/// Directory names that are never descended into or indexed.
pub const default_excludes = [_][]const u8{
    ".git",           ".hg",          ".svn",        "node_modules", ".npm",       ".cache",
    ".Trash",         ".zig-cache",   "zig-cache",   "zig-out",      "__pycache__", ".venv",
    ".gradle",        ".cargo",       ".rustup",     ".nix-defexpr", ".DS_Store",   ".Spotlight-V100",
    ".fseventsd",     ".DocumentRevisions-V100", ".TemporaryItems", ".homebrew",
};

/// Directories with these suffixes are macOS bundles: indexed as one entry, not descended into.
const package_suffixes = [_][]const u8{
    ".app",         ".photoslibrary", ".framework", ".bundle", ".musiclibrary",
    ".tvlibrary",   ".imovielibrary", ".fcpbundle", ".xcarchive", ".kext",
    ".plugin",      ".appex",
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

const schema =
    \\PRAGMA journal_mode=WAL;
    \\PRAGMA synchronous=NORMAL;
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
;

pub fn open(gpa: Allocator, io: Io, db_path: [:0]const u8) !*Index {
    const db = try sqlite.Db.open(db_path);
    errdefer db.close();
    try db.exec(schema);
    const self = try gpa.create(Index);
    self.* = .{ .gpa = gpa, .io = io, .db = db };
    try self.reload();
    return self;
}

pub fn close(self: *Index) void {
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
    const st = try self.db.prepare("SELECT path FROM roots ORDER BY path");
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
    const st = try self.db.prepare("SELECT pattern FROM excludes ORDER BY pattern");
    defer st.finalize();
    var list: std.ArrayList([]u8) = .empty;
    errdefer {
        for (list.items) |r| gpa.free(r);
        list.deinit(gpa);
    }
    while (try st.step()) try list.append(gpa, try gpa.dupe(u8, st.text(0)));
    return list.toOwnedSlice(gpa);
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
    return count;
}

/// Re-scans every saved root. Returns the total number of entries seen.
pub fn reindexAll(self: *Index, progress: ?ProgressFn, ctx: ?*anyopaque) !u64 {
    const list = try self.roots(self.gpa);
    defer freeRoots(self.gpa, list);
    var total: u64 = 0;
    for (list) |r| total += self.indexRoot(r, progress, ctx) catch 0;
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
