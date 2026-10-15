//! `seek` command-line tool.
//!
//!   seek index [DIR...]     scan folders (default: every saved folder)
//!   seek find QUERY... [-n N] [-l]
//!   seek roots | seek stats
//!
//! Uses $SEEK_DB or the platform default database (shared with the app).

const std = @import("std");
const Io = std.Io;
const Index = @import("Index.zig");

const usage =
    \\usage:
    \\  seek index [DIR...]          scan folders (default: all saved folders)
    \\  seek find QUERY... [-n N] [-l]
    \\  seek roots                   list saved folders
    \\  seek stats                   index size, database and log location
    \\
;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    const gpa = init.gpa;
    const args = try init.minimal.args.toSlice(arena);

    var out_buf: [8192]u8 = undefined;
    var out_file: Io.File.Writer = .init(.stdout(), io, &out_buf);
    const out = &out_file.interface;
    defer out.flush() catch {};

    if (args.len < 2) {
        try out.writeAll(usage);
        return;
    }
    const cmd = args[1];

    const db_path = try Index.defaultDbPath(arena, io);
    const idx = Index.open(gpa, io, db_path) catch |err| {
        std.debug.print("seek: cannot open {s}: {t}\n", .{ db_path, err });
        std.process.exit(1);
    };
    defer idx.close();
    {
        // Set when opening had to replace a damaged database: results will be empty until a rescan.
        var err_buf: [Index.error_message_max]u8 = undefined;
        const msg = idx.lastError(&err_buf);
        if (msg.len > 0) std.debug.print("seek: {s} (see {s})\n", .{ msg, idx.logPath() });
    }

    if (std.mem.eql(u8, cmd, "index")) {
        const t0 = Io.Timestamp.now(io, .awake);
        var total: u64 = 0;
        if (args.len > 2) {
            for (args[2..]) |dir| {
                var buf: [std.fs.max_path_bytes]u8 = undefined;
                const n = Io.Dir.cwd().realPathFile(io, dir, &buf) catch |err| {
                    std.debug.print("seek: {s}: {t}\n", .{ dir, err });
                    continue;
                };
                const abs = buf[0..n];
                const seen = try idx.indexRoot(abs, null, null);
                try out.print("{s}: {d} entries\n", .{ abs, seen });
                total += seen;
            }
        } else {
            const roots = try idx.roots(gpa);
            defer Index.freeRoots(gpa, roots);
            if (roots.len == 0) {
                try out.writeAll("no saved folders yet: run `seek index DIR`\n");
                return;
            }
            for (roots) |r| {
                const seen = idx.indexRoot(r, null, null) catch |err| {
                    std.debug.print("seek: {s}: {t}\n", .{ r, err });
                    continue;
                };
                try out.print("{s}: {d} entries\n", .{ r, seen });
                total += seen;
            }
        }
        const ms = @divTrunc(t0.untilNow(io, .awake).nanoseconds, std.time.ns_per_ms);
        try out.print("indexed {d} entries in {d} ms\n", .{ total, ms });
    } else if (std.mem.eql(u8, cmd, "find")) {
        var limit: usize = 20;
        var long = false;
        var q: std.ArrayList(u8) = .empty;
        var i: usize = 2;
        while (i < args.len) : (i += 1) {
            const a = args[i];
            if (std.mem.eql(u8, a, "-n") and i + 1 < args.len) {
                i += 1;
                limit = std.fmt.parseInt(usize, args[i], 10) catch 20;
            } else if (std.mem.eql(u8, a, "-l")) {
                long = true;
            } else {
                if (q.items.len > 0) try q.append(arena, ' ');
                try q.appendSlice(arena, a);
            }
        }
        const hits = try arena.alloc(Index.Hit, @min(@max(limit, 1), 256));
        const now: i64 = @intCast(@divTrunc(Io.Timestamp.now(io, .real).nanoseconds, std.time.ns_per_s));
        const t0 = Io.Timestamp.now(io, .awake);
        const n = try idx.search(arena, q.items, now, hits);
        const us: u64 = @intCast(@divTrunc(t0.untilNow(io, .awake).nanoseconds, std.time.ns_per_us));
        for (hits[0..n]) |h| {
            if (long) {
                try out.print("{d:>6} {d:>12} {s}{s}\n", .{ h.score, h.size, h.path, if (h.is_dir) "/" else "" });
            } else {
                try out.print("{s}{s}\n", .{ h.path, if (h.is_dir) "/" else "" });
            }
        }
        std.debug.print("{d} results from {d} entries in {d}.{d:0>3} ms\n", .{ n, idx.fileCount(), @divTrunc(us, 1000), @mod(us, 1000) });
    } else if (std.mem.eql(u8, cmd, "roots")) {
        const roots = try idx.roots(gpa);
        defer Index.freeRoots(gpa, roots);
        for (roots) |r| try out.print("{s}\n", .{r});
    } else if (std.mem.eql(u8, cmd, "stats")) {
        try out.print("entries: {d}\ndatabase: {s}\nlog: {s}\n", .{ idx.fileCount(), db_path, idx.logPath() });
    } else {
        try out.writeAll(usage);
    }
}
