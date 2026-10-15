//! C ABI for libseek (see include/seek.h). The native UI shells link this.

const std = @import("std");
const Index = @import("Index.zig");

const gpa = std.heap.c_allocator;

const Handle = struct {
    threaded: std.Io.Threaded,
    index: *Index,
    results: std.heap.ArenaAllocator,
    hits: [256]Index.Hit = undefined,
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
    handle(p).index.addRoot(std.mem.span(path)) catch return -1;
    return 0;
}

export fn seek_root_count(p: *anyopaque) u32 {
    const idx = handle(p).index;
    const list = idx.roots(gpa) catch return 0;
    defer Index.freeRoots(gpa, list);
    return @intCast(list.len);
}

export fn seek_index_root(p: *anyopaque, path: [*:0]const u8, progress: ?Index.ProgressFn, ctx: ?*anyopaque) i64 {
    const n = handle(p).index.indexRoot(std.mem.span(path), progress, ctx) catch return -1;
    return @intCast(n);
}

export fn seek_reindex_all(p: *anyopaque, progress: ?Index.ProgressFn, ctx: ?*anyopaque) i64 {
    const n = handle(p).index.reindexAll(progress, ctx) catch return -1;
    return @intCast(n);
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
    const n = h.index.searchFiltered(h.results.allocator(), std.mem.span(query), f, now, h.hits[0..want]) catch return 0;
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
    const n = h.index.sameSize(h.results.allocator(), size, h.hits[0..want]) catch return 0;
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

pub const StrFn = *const fn (ctx: ?*anyopaque, s: [*:0]const u8, n: u64) callconv(.c) void;

/// Calls `cb` once per saved folder with its path and indexed entry count. May wait for a running scan.
export fn seek_list_roots(p: *anyopaque, cb: StrFn, ctx: ?*anyopaque) void {
    const idx = handle(p).index;
    const list = idx.roots(gpa) catch return;
    defer Index.freeRoots(gpa, list);
    for (list) |r| {
        const z = gpa.dupeSentinel(u8, r, 0) catch continue;
        defer gpa.free(z);
        cb(ctx, z.ptr, idx.rootFileCount(r));
    }
}

export fn seek_remove_root(p: *anyopaque, path: [*:0]const u8) c_int {
    handle(p).index.removeRoot(std.mem.span(path)) catch return -1;
    return 0;
}

/// User exclusions: a name or `*` pattern (`*.log`, `build`), or an absolute folder path.
/// Takes effect on the next scan.
export fn seek_add_exclude(p: *anyopaque, pattern: [*:0]const u8) c_int {
    handle(p).index.addExclude(std.mem.span(pattern)) catch return -1;
    return 0;
}

export fn seek_remove_exclude(p: *anyopaque, pattern: [*:0]const u8) c_int {
    handle(p).index.removeExclude(std.mem.span(pattern)) catch return -1;
    return 0;
}

export fn seek_list_excludes(p: *anyopaque, cb: StrFn, ctx: ?*anyopaque) void {
    const list = handle(p).index.excludes(gpa) catch return;
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

test {
    _ = Index;
    _ = @import("fuzzy.zig");
}
