//! Benchmark for the Seek core at scale. Not shipped; run it with `zig build bench`.
//!
//!   bench scan   [--entries N] [--dir DIR]             build the tree if needed, then time a first
//!                                                      scan and a rescan with nothing changed
//!   bench search [--dir DIR] [--reps N] [--enforce]    in a fresh process: load time, idle memory
//!                                                      and search latency over the scanned index
//!   bench clean  [--dir DIR]                           delete the generated tree and database
//!
//! The tree is real (empty files in real folders) so a scan pays what it pays on a user's disk.
//! It is generated once from a fixed seed and reused, so runs are comparable. Budgets and the
//! numbers measured so far are in docs/benchmarks.md.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Index = @import("Index");

/// What 1.0 has to meet with 1,000,000 entries indexed (docs/benchmarks.md).
pub const budgets = struct {
    pub const entries: u64 = 1_000_000;
    pub const search_p99_ms: f64 = 30;
    pub const idle_memory_mb: f64 = 200;
    pub const rescan_rows_written: i64 = 0;
};

const default_dir = ".zig-cache/seek-bench";
const default_reps = 40;
/// Bump when `Generator` changes what it produces, so old trees are rebuilt.
const tree_version = 1;

// ---------------------------------------------------------------- generator

const words = [_][]const u8{
    "report",    "invoice",  "budget",   "meeting",  "notes",     "draft",     "final",     "summary",  "proposal",  "contract",
    "design",    "project",  "client",   "review",   "plan",      "photo",     "holiday",   "family",   "receipt",   "tax",
    "bank",      "letter",   "resume",   "cover",    "slides",    "talk",      "paper",     "thesis",   "chapter",   "figure",
    "data",      "export",   "backup",   "archive",  "config",    "server",    "worker",    "module",   "parser",    "index",
    "search",    "render",   "layout",   "theme",    "icon",      "logo",      "banner",    "mockup",   "sketch",    "wireframe",
    "quarterly", "annual",   "monthly",  "weekly",   "roadmap",   "release",   "changelog", "readme",   "license",   "manual",
    "recipe",    "garden",   "travel",   "ticket",   "booking",   "insurance", "medical",   "school",   "homework",  "syllabus",
    "music",     "podcast",  "episode",  "video",    "trailer",   "sample",    "template",  "schedule", "agenda",    "minutes",
    "analysis",  "forecast", "pipeline", "metrics",  "dashboard", "survey",    "results",   "feedback", "interview", "onboarding",
    "utils",     "helpers",  "tests",    "fixtures", "assets",    "vendor",    "scripts",   "tools",    "docs",      "examples",
};

/// Repeats set the mix: documents and code are common, archives are rare.
const extensions = [_][]const u8{
    "pdf", "pdf", "pdf",  "docx", "docx", "txt",  "txt",  "md",   "md",   "xlsx",
    "csv", "csv", "pptx", "jpg",  "jpg",  "jpg",  "png",  "png",  "heic", "gif",
    "mp3", "m4a", "mp4",  "mov",  "zip",  "dmg",  "js",   "ts",   "py",   "py",
    "go",  "rs",  "c",    "h",    "json", "json", "yaml", "html", "css",  "swift",
};

/// Produces the same sequence of relative paths for the same seed: folders before anything
/// inside them, no path twice. At most one entry in thirteen is a folder, nested at most `max_depth` deep.
pub const Generator = struct {
    gpa: Allocator,
    prng: std.Random.DefaultPrng,
    /// Every folder made so far, as slices of `dir_text`. Entry 0 is the tree root (empty path).
    dirs: std.ArrayList(DirRef) = .empty,
    dir_text: std.ArrayList(u8) = .empty,
    seen: std.AutoHashMapUnmanaged(u64, void) = .empty,
    made: u64 = 0,
    buf: [max_path]u8 = undefined,

    const max_depth = 7;
    const max_path = 512;
    const DirRef = struct { off: u32, len: u16, depth: u8 };

    pub const Item = struct {
        /// Relative to the tree root; valid until the next call.
        path: []const u8,
        is_dir: bool,
    };

    pub fn init(gpa: Allocator, seed: u64) !Generator {
        var g: Generator = .{ .gpa = gpa, .prng = .init(seed) };
        try g.dirs.append(gpa, .{ .off = 0, .len = 0, .depth = 0 });
        return g;
    }

    pub fn deinit(g: *Generator) void {
        g.dirs.deinit(g.gpa);
        g.dir_text.deinit(g.gpa);
        g.seen.deinit(g.gpa);
    }

    pub fn next(g: *Generator) !Item {
        const r = g.prng.random();
        const parent = g.dirs.items[r.uintLessThan(usize, g.dirs.items.len)];
        // The first few entries are folders so files don't all pile into the root.
        const is_dir = parent.depth < max_depth and (g.dirs.items.len < 16 or r.uintLessThan(u8, 13) == 0);

        var w: Io.Writer = .fixed(&g.buf);
        if (parent.len > 0) {
            try w.writeAll(g.dir_text.items[parent.off..][0..parent.len]);
            try w.writeByte('/');
        }
        const ext: []const u8 = if (is_dir) "" else extensions[r.uintLessThan(usize, extensions.len)];
        try writeStem(&w, r, is_dir);
        const stem_end = w.end;
        if (ext.len > 0) try w.print(".{s}", .{ext});

        // A name already used in this folder gets the entry's sequence number, which is unique.
        const gop = try g.seen.getOrPut(g.gpa, std.hash.Wyhash.hash(0, w.buffered()));
        if (gop.found_existing) {
            w.end = stem_end;
            try w.print("-{d}", .{g.made});
            if (ext.len > 0) try w.print(".{s}", .{ext});
            try g.seen.put(g.gpa, std.hash.Wyhash.hash(0, w.buffered()), {});
        }

        const path = w.buffered();
        if (is_dir) {
            const off = g.dir_text.items.len;
            try g.dir_text.appendSlice(g.gpa, path);
            try g.dirs.append(g.gpa, .{ .off = @intCast(off), .len = @intCast(path.len), .depth = parent.depth + 1 });
        }
        g.made += 1;
        return .{ .path = path, .is_dir = is_dir };
    }

    fn word(r: std.Random) []const u8 {
        return words[r.uintLessThan(usize, words.len)];
    }

    fn writeStem(w: *Io.Writer, r: std.Random, is_dir: bool) !void {
        const year = 2015 + @as(u32, r.uintLessThan(u8, 12));
        if (is_dir) {
            switch (r.uintLessThan(u8, 4)) {
                0 => try w.print("{s}", .{word(r)}),
                1 => try w.print("{s}-{s}", .{ word(r), word(r) }),
                2 => try w.print("{s} {d}", .{ word(r), year }),
                else => try w.print("{d}-{d:0>2}", .{ year, 1 + r.uintLessThan(u8, 12) }),
            }
            return;
        }
        switch (r.uintLessThan(u8, 6)) {
            0 => try w.print("{s}-{s}", .{ word(r), word(r) }),
            1 => try w.print("{s}_{s}_{d}", .{ word(r), word(r), year }),
            2 => try w.print("IMG_{d:0>4}", .{r.uintLessThan(u16, 10_000)}),
            3 => try w.print("{s}", .{word(r)}),
            4 => try w.print("{s} {s} v{d}", .{ word(r), word(r), 1 + r.uintLessThan(u8, 9) }),
            else => try w.print("{d}-{d:0>2}-{d:0>2} {s}", .{ year, 1 + r.uintLessThan(u8, 12), 1 + r.uintLessThan(u8, 28), word(r) }),
        }
    }
};

// ---------------------------------------------------------------- memory

const RusageInfoV2 = extern struct {
    uuid: [16]u8,
    user_time: u64,
    system_time: u64,
    pkg_idle_wkups: u64,
    interrupt_wkups: u64,
    pageins: u64,
    wired_size: u64,
    resident_size: u64,
    phys_footprint: u64,
    proc_start_abstime: u64,
    proc_exit_abstime: u64,
    child_user_time: u64,
    child_system_time: u64,
    child_pkg_idle_wkups: u64,
    child_interrupt_wkups: u64,
    child_pageins: u64,
    child_elapsed_abstime: u64,
    diskio_bytesread: u64,
    diskio_byteswritten: u64,
};
extern "c" fn proc_pid_rusage(pid: c_int, flavor: c_int, buffer: *RusageInfoV2) c_int;

/// The memory macOS charges to this process right now (what Activity Monitor shows), in bytes.
/// Null where there is no cheap way to ask.
fn footprintBytes() ?u64 {
    if (builtin.os.tag != .macos) return null;
    var info: RusageInfoV2 = undefined;
    if (proc_pid_rusage(std.c.getpid(), 2, &info) != 0) return null;
    return info.phys_footprint;
}

/// The most memory this process has held at once, in bytes.
fn peakBytes() u64 {
    const ru = std.posix.getrusage(0);
    const raw: u64 = @intCast(@max(ru.maxrss, 0));
    return if (builtin.os.tag == .macos) raw else raw * 1024; // Linux reports kilobytes
}

fn mb(bytes: u64) f64 {
    return @as(f64, @floatFromInt(bytes)) / (1024.0 * 1024.0);
}

fn ms(ns: i96) f64 {
    return @as(f64, @floatFromInt(ns)) / std.time.ns_per_ms;
}

// ---------------------------------------------------------------- command line

const Options = struct {
    entries: u64 = budgets.entries,
    dir: []const u8 = default_dir,
    reps: usize = default_reps,
    enforce: bool = false,
};

const usage =
    \\usage:
    \\  bench scan   [--entries N] [--dir DIR]            build the tree if needed, time a scan and a rescan
    \\  bench search [--dir DIR] [--reps N] [--enforce]   load time, idle memory and search latency
    \\  bench clean  [--dir DIR]                          delete the generated tree and database
    \\
;

fn parseOptions(args: []const []const u8) !Options {
    var o: Options = .{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--enforce")) {
            o.enforce = true;
            continue;
        }
        if (i + 1 >= args.len) return error.BadArguments;
        i += 1;
        const v = args[i];
        if (std.mem.eql(u8, a, "--entries")) {
            o.entries = try std.fmt.parseInt(u64, v, 10);
            if (o.entries < 16) return error.BadArguments;
        } else if (std.mem.eql(u8, a, "--dir")) {
            o.dir = v;
        } else if (std.mem.eql(u8, a, "--reps")) {
            o.reps = try std.fmt.parseInt(usize, v, 10);
            if (o.reps == 0) return error.BadArguments;
        } else return error.BadArguments;
    }
    return o;
}

const Paths = struct {
    work: Io.Dir,
    tree_abs: []const u8,
    db_path: [:0]const u8,
};

fn openWork(arena: Allocator, io: Io, dir: []const u8) !Paths {
    try Io.Dir.cwd().createDirPath(io, dir);
    const abs = try Io.Dir.cwd().realPathFileAlloc(io, dir, arena);
    return .{
        .work = try Io.Dir.openDirAbsolute(io, abs, .{}),
        .tree_abs = try std.fmt.allocPrint(arena, "{s}/tree", .{abs}),
        .db_path = try std.fmt.allocPrintSentinel(arena, "{s}/seek.db", .{abs}, 0),
    };
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    var out_buf: [4096]u8 = undefined;
    var out_file: Io.File.Writer = .init(.stdout(), io, &out_buf);
    const out = &out_file.interface;
    defer out.flush() catch {};

    const cmd: []const u8 = if (args.len > 1) args[1] else "";
    const opts = parseOptions(if (args.len > 2) args[2..] else &.{}) catch {
        try out.writeAll(usage);
        try out.flush();
        std.process.exit(2);
    };

    const ok = if (std.mem.eql(u8, cmd, "scan"))
        try runScan(init.gpa, arena, io, out, opts)
    else if (std.mem.eql(u8, cmd, "search"))
        try runSearch(init.gpa, arena, io, out, opts)
    else if (std.mem.eql(u8, cmd, "clean"))
        try runClean(arena, io, out, opts)
    else {
        try out.writeAll(usage);
        try out.flush();
        std.process.exit(2);
    };
    try out.flush();
    if (!ok and opts.enforce) std.process.exit(1);
}

// ---------------------------------------------------------------- tree

const marker_name = "tree.meta";

fn markerText(buf: []u8, entries: u64) []const u8 {
    return std.fmt.bufPrint(buf, "seek-bench tree v{d} entries {d}\n", .{ tree_version, entries }) catch unreachable;
}

/// Makes sure `work/tree` holds exactly `entries` generated entries. The marker file is what
/// says the folder is ours: a `tree` folder without one is never touched.
fn ensureTree(gpa: Allocator, io: Io, work: Io.Dir, entries: u64) !void {
    var want_buf: [96]u8 = undefined;
    const want = markerText(&want_buf, entries);
    var have_buf: [96]u8 = undefined;
    const have: ?[]const u8 = work.readFile(io, marker_name, &have_buf) catch |err| switch (err) {
        error.FileNotFound => null,
        else => |e| return e,
    };
    if (have) |h| {
        if (std.mem.eql(u8, h, want)) return;
        std.debug.print("bench: removing the previous tree\n", .{});
        try work.deleteTree(io, "tree");
    } else if (work.access(io, "tree", .{})) |_| {
        return error.TreeFolderIsNotOurs;
    } else |_| {}

    // "building" until the last entry exists, so an interrupted run is rebuilt, not trusted.
    try work.writeFile(io, .{ .sub_path = marker_name, .data = "seek-bench tree building\n" });
    try work.createDir(io, "tree", .default_dir);
    var tree = try work.openDir(io, "tree", .{});
    defer tree.close(io);

    var gen: Generator = try .init(gpa, 0x5eec);
    defer gen.deinit();
    const t0 = Io.Timestamp.now(io, .awake);
    while (gen.made < entries) {
        const item = try gen.next();
        if (item.is_dir) {
            try tree.createDir(io, item.path, .default_dir);
        } else {
            const f = try tree.createFile(io, item.path, .{ .exclusive = true });
            f.close(io);
        }
        if (gen.made % 100_000 == 0) std.debug.print("bench: created {d} of {d} entries\n", .{ gen.made, entries });
    }
    try work.writeFile(io, .{ .sub_path = marker_name, .data = want });
    std.debug.print("bench: tree of {d} entries built in {d:.1} s\n", .{ entries, ms(t0.untilNow(io, .awake).nanoseconds) / 1000 });
}

fn fileSize(io: Io, dir: Io.Dir, name: []const u8) u64 {
    const st = dir.statFile(io, name, .{}) catch return 0;
    return st.size;
}

const db_files = [_][]const u8{ "seek.db", "seek.db-wal", "seek.db-shm", "seek.log", "seek.log.1" };

// ---------------------------------------------------------------- scan

fn runScan(gpa: Allocator, arena: Allocator, io: Io, out: *Io.Writer, opts: Options) !bool {
    const p = try openWork(arena, io, opts.dir);
    try ensureTree(gpa, io, p.work, opts.entries);
    for (db_files) |f| p.work.deleteFile(io, f) catch {};

    const idx = try Index.open(gpa, io, p.db_path);
    defer idx.close();

    var t = Io.Timestamp.now(io, .awake);
    const seen = try idx.indexRoot(p.tree_abs, null, null);
    const first_ns = t.untilNow(io, .awake).nanoseconds;
    if (seen != opts.entries) {
        try out.print("scan saw {d} entries, the tree holds {d}\n", .{ seen, opts.entries });
        return error.TreeAndScanDisagree;
    }

    const changes_before = idx.db.totalChanges();
    t = Io.Timestamp.now(io, .awake);
    _ = try idx.indexRoot(p.tree_abs, null, null);
    const rescan_ns = t.untilNow(io, .awake).nanoseconds;
    const rescan_rows = idx.db.totalChanges() - changes_before;

    const first_s = ms(first_ns) / 1000;
    try out.print("scan ({d} entries)\n", .{seen});
    try out.print("  first scan             {d:>10.2} s   {d:.0} entries/s\n", .{ first_s, @as(f64, @floatFromInt(seen)) / first_s });
    try out.print("  rescan, nothing changed{d:>10.2} s   {d} rows written\n", .{ ms(rescan_ns) / 1000, rescan_rows });
    try out.print("  database               {d:>10.1} MB  (+ {d:.1} MB write-ahead log)\n", .{
        mb(fileSize(io, p.work, "seek.db")), mb(fileSize(io, p.work, "seek.db-wal")),
    });
    try out.print("  peak memory            {d:>10.1} MB\n", .{mb(peakBytes())});

    const ok = rescan_rows <= budgets.rescan_rows_written;
    try out.print("  budget: a rescan with nothing changed writes {d} rows: {s}\n\n", .{ budgets.rescan_rows_written, verdict(ok) });
    return ok;
}

fn verdict(ok: bool) []const u8 {
    return if (ok) "met" else "NOT MET";
}

// ---------------------------------------------------------------- search

const QueryClass = struct { label: []const u8, queries: []const []const u8 };

/// One-character queries are the worst case (almost nothing is rejected by the character mask);
/// each class also has a query that matches nothing, which is the cheapest.
const query_classes = [_]QueryClass{
    .{ .label = "1 character ", .queries = &.{ "a", "r", "7", "q" } },
    .{ .label = "3 characters", .queries = &.{ "rep", "inv", "img", "zqx" } },
    .{ .label = "8 characters", .queries = &.{ "invoice-", "quarterl", "rprtfnl2", "img_4821" } },
    .{ .label = "several words", .queries = &.{ "tax 2021 pdf", "meeting notes md", "budget final xlsx" } },
};

fn percentile(sorted: []const i96, pct: usize) i96 {
    if (sorted.len == 0) return 0;
    const rank = (sorted.len * pct + 99) / 100; // nearest-rank, 1-based
    return sorted[@max(rank, 1) - 1];
}

fn runSearch(gpa: Allocator, arena: Allocator, io: Io, out: *Io.Writer, opts: Options) !bool {
    const p = try openWork(arena, io, opts.dir);
    p.work.access(io, "seek.db", .{}) catch {
        try out.writeAll("no index to search: run `bench scan` first\n");
        return error.NoIndex;
    };

    var t = Io.Timestamp.now(io, .awake);
    const idx = try Index.open(gpa, io, p.db_path);
    defer idx.close();
    const open_ns = t.untilNow(io, .awake).nanoseconds;
    const entries = idx.fileCount();

    try out.print("search ({d} entries, {d} runs per query)\n", .{ entries, opts.reps });
    try out.print("  open and load          {d:>10.2} s\n", .{ms(open_ns) / 1000});
    if (footprintBytes()) |b| try out.print("  memory after loading   {d:>10.1} MB\n", .{mb(b)});

    var scratch: std.heap.ArenaAllocator = .init(gpa);
    defer scratch.deinit();
    var hits: [256]Index.Hit = undefined;
    const now: i64 = @intCast(@divTrunc(Io.Timestamp.now(io, .real).nanoseconds, std.time.ns_per_s));
    var samples: std.ArrayList(i96) = .empty;
    defer samples.deinit(gpa);

    var worst_p99: i96 = 0;
    try out.writeAll("  latency                       p50        p99        max\n");
    for (query_classes) |class| {
        samples.clearRetainingCapacity();
        for (class.queries) |q| {
            for (0..opts.reps) |_| {
                _ = scratch.reset(.retain_capacity);
                t = Io.Timestamp.now(io, .awake);
                _ = try idx.search(scratch.allocator(), q, now, &hits);
                try samples.append(gpa, t.untilNow(io, .awake).nanoseconds);
            }
        }
        std.mem.sort(i96, samples.items, {}, std.sort.asc(i96));
        const p99 = percentile(samples.items, 99);
        worst_p99 = @max(worst_p99, p99);
        try out.print("    {s:<14}      {d:>8.2} ms {d:>8.2} ms {d:>8.2} ms\n", .{
            class.label, ms(percentile(samples.items, 50)), ms(p99), ms(samples.items[samples.items.len - 1]),
        });
    }
    // Measured after the searches, not straight after loading: the system only charges for the
    // snapshot's pages once they have been read, and an app that has been used has read them all.
    const idle = footprintBytes();
    if (idle) |b| try out.print("  idle memory            {d:>10.1} MB   (after searching)\n", .{mb(b)});
    try out.print("  peak memory            {d:>10.1} MB\n", .{mb(peakBytes())});

    const latency_ok = ms(worst_p99) <= budgets.search_p99_ms;
    const memory_ok = if (idle) |b| mb(b) <= budgets.idle_memory_mb else true;
    try out.print("  budget: search p99 under {d} ms: {s}\n", .{ budgets.search_p99_ms, verdict(latency_ok) });
    if (idle != null) try out.print("  budget: idle memory under {d} MB: {s}\n", .{ budgets.idle_memory_mb, verdict(memory_ok) });
    if (entries != budgets.entries) try out.print("  (budgets are set for {d} entries; this index has {d})\n", .{ budgets.entries, entries });
    return latency_ok and memory_ok;
}

// ---------------------------------------------------------------- clean

fn runClean(arena: Allocator, io: Io, out: *Io.Writer, opts: Options) !bool {
    const p = try openWork(arena, io, opts.dir);
    // Only what this tool made: the tree is removed only when its marker says it is ours.
    if (p.work.access(io, marker_name, .{})) |_| {
        try p.work.deleteTree(io, "tree");
        try p.work.deleteFile(io, marker_name);
    } else |_| {}
    for (db_files) |f| p.work.deleteFile(io, f) catch {};
    try out.print("removed the benchmark tree and database from {s}\n", .{opts.dir});
    return true;
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

test "the generator is deterministic and never repeats a path" {
    var a: Generator = try .init(testing.allocator, 42);
    defer a.deinit();
    var b: Generator = try .init(testing.allocator, 42);
    defer b.deinit();
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer {
        var it = seen.keyIterator();
        while (it.next()) |k| testing.allocator.free(k.*);
        seen.deinit(testing.allocator);
    }
    for (0..20_000) |_| {
        const x = try a.next();
        const y = try b.next();
        try testing.expectEqualStrings(x.path, y.path);
        try testing.expectEqual(x.is_dir, y.is_dir);
        const gop = try seen.getOrPut(testing.allocator, x.path);
        try testing.expect(!gop.found_existing);
        gop.key_ptr.* = try testing.allocator.dupe(u8, x.path);
    }
    try testing.expectEqual(@as(u64, 20_000), a.made);
}

test "a different seed gives a different tree" {
    var a: Generator = try .init(testing.allocator, 1);
    defer a.deinit();
    var b: Generator = try .init(testing.allocator, 2);
    defer b.deinit();
    var differ = false;
    for (0..50) |_| {
        if (!std.mem.eql(u8, (try a.next()).path, (try b.next()).path)) differ = true;
    }
    try testing.expect(differ);
}

test "every entry's folder was generated before it, and depth is bounded" {
    var g: Generator = try .init(testing.allocator, 7);
    defer g.deinit();
    var dirs: std.StringHashMapUnmanaged(void) = .empty;
    defer {
        var it = dirs.keyIterator();
        while (it.next()) |k| testing.allocator.free(k.*);
        dirs.deinit(testing.allocator);
    }
    var folders: usize = 0;
    for (0..20_000) |_| {
        const item = try g.next();
        if (std.fs.path.dirname(item.path)) |parent| try testing.expect(dirs.contains(parent));
        try testing.expect(std.mem.count(u8, item.path, "/") <= Generator.max_depth); // a file in the deepest folder
        if (item.is_dir) {
            folders += 1;
            try dirs.put(testing.allocator, try testing.allocator.dupe(u8, item.path), {});
        }
    }
    // About one in thirteen; a wide band so the test is about shape, not the exact stream.
    try testing.expect(folders > 1_000 and folders < 2_500);
}

test "generated names are ones a scan keeps" {
    var g: Generator = try .init(testing.allocator, 3);
    defer g.deinit();
    for (0..5_000) |_| {
        const name = std.fs.path.basename((try g.next()).path);
        for (Index.default_excludes) |ex| try testing.expect(!std.mem.eql(u8, name, ex));
        try testing.expect(name.len > 0 and name[0] != '.');
    }
}

test "percentile uses the nearest rank" {
    const v = [_]i96{ 10, 20, 30, 40, 50, 60, 70, 80, 90, 100 };
    try testing.expectEqual(@as(i96, 50), percentile(&v, 50));
    try testing.expectEqual(@as(i96, 100), percentile(&v, 99));
    try testing.expectEqual(@as(i96, 100), percentile(&v, 100));
    try testing.expectEqual(@as(i96, 10), percentile(&v, 1));
    try testing.expectEqual(@as(i96, 0), percentile(&.{}, 50));
    try testing.expectEqual(@as(i96, 7), percentile(&.{7}, 99));
}

test "parseOptions reads every flag and rejects nonsense" {
    const o = try parseOptions(&.{ "--entries", "5000", "--dir", "/tmp/x", "--reps", "3", "--enforce" });
    try testing.expectEqual(@as(u64, 5000), o.entries);
    try testing.expectEqualStrings("/tmp/x", o.dir);
    try testing.expectEqual(@as(usize, 3), o.reps);
    try testing.expect(o.enforce);
    try testing.expectEqual(budgets.entries, (try parseOptions(&.{})).entries);
    try testing.expectError(error.BadArguments, parseOptions(&.{"--entries"}));
    try testing.expectError(error.BadArguments, parseOptions(&.{ "--entries", "3" }));
    try testing.expectError(error.BadArguments, parseOptions(&.{ "--reps", "0" }));
    try testing.expectError(error.BadArguments, parseOptions(&.{ "--what", "1" }));
}
