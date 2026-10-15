//! C ABI for libseek (see include/seek.h). The native UI shells link this.

const std = @import("std");
const Index = @import("Index.zig");

const gpa = std.heap.c_allocator;

const Handle = struct {
    threaded: std.Io.Threaded,
    index: *Index,
    results: std.heap.ArenaAllocator,
    hits: [256]Index.Hit = undefined,
    /// Backing store for seek_last_error; only touched by the thread that calls it.
    last_error: [Index.error_message_max + 1]u8 = @splat(0),
};

pub const SeekResult = extern struct {
    path: [*:0]const u8,
    name_offset: u32,
    is_dir: u8,
    size: u64,
    mtime: i64,
    score: i32,
};

fn handle(p: *anyopaque) *Handle {
    return @ptrCast(@alignCast(p));
}

export fn seek_open(db_path: ?[*:0]const u8) ?*anyopaque {
    const h = gpa.create(Handle) catch return null;
    h.threaded = .init(gpa, .{});
    const io = h.threaded.io();
    const path: [:0]u8 = if (db_path) |p|
        gpa.dupeSentinel(u8, std.mem.span(p), 0) catch return fail(h)
    else
        Index.defaultDbPath(gpa, io) catch return fail(h);
    defer gpa.free(path);
    h.index = Index.open(gpa, io, path) catch return fail(h);
    h.results = .init(gpa);
    h.hits = undefined;
    return h;
}

/// Records `err` for seek_last_error and returns the C API's failure value.
fn fail2(h: *Handle, what: []const u8, err: anyerror) i64 {
    h.index.recordError(what, err);
    return -1;
}

/// Maps a core result to 0 / -1, recording the failure.
fn status(h: *Handle, what: []const u8, result: anyerror!void) c_int {
    result catch |err| {
        h.index.recordError(what, err);
        return -1;
    };
    return 0;
}

fn fail(h: *Handle) ?*anyopaque {
    h.threaded.deinit();
    gpa.destroy(h);
    return null;
}

export fn seek_close(p: ?*anyopaque) void {
    const h = handle(p orelse return);
    h.index.close();
    h.results.deinit();
    h.threaded.deinit();
    gpa.destroy(h);
}

export fn seek_add_root(p: *anyopaque, path: [*:0]const u8) c_int {
    return status(handle(p), "add folder", handle(p).index.addRoot(std.mem.span(path)));
}

export fn seek_root_count(p: *anyopaque) u32 {
    const idx = handle(p).index;
    const list = idx.roots(gpa) catch |err| {
        idx.recordError("list folders", err);
        return 0;
    };
    defer Index.freeRoots(gpa, list);
    return @intCast(list.len);
}

export fn seek_index_root(p: *anyopaque, path: [*:0]const u8, progress: ?Index.ProgressFn, ctx: ?*anyopaque) i64 {
    const h = handle(p);
    const n = h.index.indexRoot(std.mem.span(path), progress, ctx) catch |err| return fail2(h, std.mem.span(path), err);
    return @intCast(n);
}

export fn seek_reindex_all(p: *anyopaque, progress: ?Index.ProgressFn, ctx: ?*anyopaque) i64 {
    const h = handle(p);
    const n = h.index.reindexAll(progress, ctx) catch |err| return fail2(h, "rescan", err);
    return @intCast(n);
}

/// Message for the most recent failure on this handle, "" if none. Valid until the next call to
/// seek_last_error on the same handle. A failure inside one root of seek_reindex_all is recorded here
/// even though the call itself succeeds.
export fn seek_last_error(p: *anyopaque) [*:0]const u8 {
    const h = handle(p);
    const msg = h.index.lastError(h.last_error[0 .. h.last_error.len - 1]);
    h.last_error[msg.len] = 0;
    return @ptrCast(&h.last_error);
}

/// Path of the diagnostics log (UTF-8, NUL-terminated), "" if there is none. Valid until seek_close.
export fn seek_log_path(p: *anyopaque) [*:0]const u8 {
    const idx = handle(p).index;
    return if (idx.log_path) |lp| lp.ptr else "";
}

export fn seek_file_count(p: *anyopaque) u64 {
    return handle(p).index.fileCount();
}

pub const SeekFilter = extern struct {
    scope: u8, // 0 any, 1 files only, 2 folders only
    kind: u8, // 0 any, 1 documents, 2 images, 3 audio, 4 video, 5 code, 6 archives
    min_size: u64, // bytes; 0 = any
    modified_after: i64, // seconds since 1970; 0 = any
};

export fn seek_search(p: *anyopaque, query: [*:0]const u8, out: [*]SeekResult, max: c_int) c_int {
    return seek_search_filtered(p, query, null, out, max);
}

export fn seek_search_filtered(p: *anyopaque, query: [*:0]const u8, filter: ?*const SeekFilter, out: [*]SeekResult, max: c_int) c_int {
    const h = handle(p);
    if (max <= 0) return 0;
    _ = h.results.reset(.retain_capacity);
    const want: usize = @min(@as(usize, @intCast(max)), h.hits.len);
    const now: i64 = @intCast(@divTrunc(std.Io.Timestamp.now(h.threaded.io(), .real).nanoseconds, std.time.ns_per_s));
    var f: Index.Filter = .{};
    if (filter) |sf| {
        f = .{
            .scope = std.enums.fromInt(Index.Filter.Scope, sf.scope) orelse .all,
            .kind = std.enums.fromInt(Index.Filter.Kind, sf.kind) orelse .any,
            .min_size = sf.min_size,
            .modified_after = sf.modified_after,
        };
    }
    const n = h.index.searchFiltered(h.results.allocator(), std.mem.span(query), f, now, h.hits[0..want]) catch |err| {
        h.index.recordError("search", err);
        return 0;
    };
    for (h.hits[0..n], 0..) |hit, i| {
        out[i] = .{
            .path = @ptrCast(hit.path.ptr),
            .name_offset = hit.name_off,
            .is_dir = @intFromBool(hit.is_dir),
            .size = hit.size,
            .mtime = hit.mtime,
            .score = hit.score,
        };
    }
    return @intCast(n);
}

/// Files of exactly `size` bytes (duplicate candidates). Shares the result buffer with seek_search.
export fn seek_find_same_size(p: *anyopaque, size: u64, out: [*]SeekResult, max: c_int) c_int {
    const h = handle(p);
    if (max <= 0) return 0;
    _ = h.results.reset(.retain_capacity);
    const want: usize = @min(@as(usize, @intCast(max)), h.hits.len);
    const n = h.index.sameSize(h.results.allocator(), size, h.hits[0..want]) catch |err| {
        h.index.recordError("find same size", err);
        return 0;
    };
    for (h.hits[0..n], 0..) |hit, i| {
        out[i] = .{
            .path = @ptrCast(hit.path.ptr),
            .name_offset = hit.name_off,
            .is_dir = 0,
            .size = hit.size,
            .mtime = hit.mtime,
            .score = 0,
        };
    }
    return @intCast(n);
}

pub const DupGroupFn = *const fn (ctx: ?*anyopaque, size: u64, paths: [*]const [*:0]const u8, mtimes: [*]const i64, count: u32) callconv(.c) void;

/// Groups files with identical content: calls `on_group` once per group, biggest saving first,
/// and returns the number of groups; -1 on failure (see seek_last_error), -2 if `progress`
/// canceled the run. Blocks while it reads files, so call it from a background thread; search,
/// scanning and the other calls stay usable meanwhile. Does not use the seek_search result buffer.
export fn seek_find_duplicates(
    p: *anyopaque,
    min_size: u64,
    progress: ?Index.DupProgressFn,
    on_group: ?DupGroupFn,
    ctx: ?*anyopaque,
) i64 {
    const idx = handle(p).index;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const groups = idx.findDuplicates(arena, min_size, progress, ctx) catch |err| {
        if (err == error.Canceled) return -2;
        idx.recordError("find duplicates", err);
        return -1;
    };
    const cb = on_group orelse return @intCast(groups.len);
    for (groups) |g| {
        const paths = arena.alloc([*:0]const u8, g.files.len) catch |err| {
            idx.recordError("find duplicates", err);
            return -1;
        };
        const mtimes = arena.alloc(i64, g.files.len) catch |err| {
            idx.recordError("find duplicates", err);
            return -1;
        };
        for (g.files, paths, mtimes) |f, *path, *mtime| {
            path.* = f.path.ptr;
            mtime.* = f.mtime;
        }
        cb(ctx, g.size, paths.ptr, mtimes.ptr, @intCast(g.files.len));
    }
    return @intCast(groups.len);
}

pub const StrFn = *const fn (ctx: ?*anyopaque, s: [*:0]const u8, n: u64) callconv(.c) void;

/// Calls `cb` once per saved folder with its path and indexed entry count. May wait for a running scan.
export fn seek_list_roots(p: *anyopaque, cb: StrFn, ctx: ?*anyopaque) void {
    const idx = handle(p).index;
    const list = idx.roots(gpa) catch |err| return idx.recordError("list folders", err);
    defer Index.freeRoots(gpa, list);
    for (list) |r| {
        const z = gpa.dupeSentinel(u8, r, 0) catch continue;
        defer gpa.free(z);
        cb(ctx, z.ptr, idx.rootFileCount(r));
    }
}

export fn seek_remove_root(p: *anyopaque, path: [*:0]const u8) c_int {
    return status(handle(p), "remove folder", handle(p).index.removeRoot(std.mem.span(path)));
}

/// User exclusions: a name or `*` pattern (`*.log`, `build`), or an absolute folder path.
/// Takes effect on the next scan.
export fn seek_add_exclude(p: *anyopaque, pattern: [*:0]const u8) c_int {
    return status(handle(p), "add exclusion", handle(p).index.addExclude(std.mem.span(pattern)));
}

export fn seek_remove_exclude(p: *anyopaque, pattern: [*:0]const u8) c_int {
    return status(handle(p), "remove exclusion", handle(p).index.removeExclude(std.mem.span(pattern)));
}

export fn seek_list_excludes(p: *anyopaque, cb: StrFn, ctx: ?*anyopaque) void {
    const idx = handle(p).index;
    const list = idx.excludes(gpa) catch |err| return idx.recordError("list exclusions", err);
    defer Index.freeRoots(gpa, list);
    for (list) |r| {
        const z = gpa.dupeSentinel(u8, r, 0) catch continue;
        defer gpa.free(z);
        cb(ctx, z.ptr, 0);
    }
}

/// Names that are always skipped (not editable).
export fn seek_list_default_excludes(cb: StrFn, ctx: ?*anyopaque) void {
    for (Index.default_excludes) |name| {
        const z = gpa.dupeSentinel(u8, name, 0) catch continue;
        defer gpa.free(z);
        cb(ctx, z.ptr, 0);
    }
}

test "seek_last_error reports failures and is never null" {
    const h_ptr = seek_open(":memory:") orelse return error.OpenFailed;
    defer seek_close(h_ptr);
    try std.testing.expectEqualStrings("", std.mem.span(seek_last_error(h_ptr)));
    try std.testing.expectEqual(@as(i64, -1), seek_index_root(h_ptr, "/definitely/not/a/real/folder", null, null));
    try std.testing.expect(std.mem.startsWith(u8, std.mem.span(seek_last_error(h_ptr)), "/definitely/not/a/real/folder: "));
}

test {
    _ = Index;
    _ = @import("fuzzy.zig");
    _ = @import("sqlite.zig");
}
