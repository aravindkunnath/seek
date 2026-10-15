//! Filename ranking. Each query token must match the file's name or path.
//! Name matches beat path matches; prefixes, exact names and word starts get
//! bonuses; a gap-penalized subsequence match catches abbreviations ("prd" -> "product-requirements").

const std = @import("std");
const ascii = std.ascii;

pub const max_tokens = 8;

pub const Query = struct {
    // Tokens are stored as offsets into `buf` (not slices) so a Query can be copied safely.
    starts: [max_tokens]u16 = undefined,
    lens: [max_tokens]u16 = undefined,
    masks: [max_tokens]u64 = undefined,
    /// Union of every token's mask: an entry must contain all of these characters.
    all_mask: u64 = 0,
    len: usize = 0,
    buf: [512]u8 = undefined,

    /// Lowercases and splits on whitespace. Extra tokens beyond `max_tokens` are ignored.
    pub fn parse(raw: []const u8) Query {
        var q: Query = .{};
        const n = @min(raw.len, q.buf.len);
        for (raw[0..n], 0..) |ch, i| q.buf[i] = ascii.toLower(ch);
        var it = std.mem.tokenizeAny(u8, q.buf[0..n], " \t\r\n");
        while (it.next()) |tok| {
            if (q.len == max_tokens) break;
            q.starts[q.len] = @intCast(tok.ptr - &q.buf);
            q.lens[q.len] = @intCast(tok.len);
            q.masks[q.len] = charMask(tok);
            q.all_mask |= q.masks[q.len];
            q.len += 1;
        }
        return q;
    }

    pub fn token(q: *const Query, i: usize) []const u8 {
        return q.buf[q.starts[i]..][0..q.lens[i]];
    }

    pub fn isEmpty(q: *const Query) bool {
        return q.len == 0;
    }
};

/// 64-bit set of the (lowercased) characters in `s`: a–z, 0–9, and others hashed
/// into the remaining bits. If an entry's mask lacks any bit of a token's mask, the
/// token can't match, so most entries are rejected with a single AND.
pub fn charMask(s: []const u8) u64 {
    var m: u64 = 0;
    for (s) |ch| m |= charBit(ch);
    return m;
}

inline fn charBit(ch: u8) u64 {
    const c = ascii.toLower(ch);
    const bit: u6 = switch (c) {
        'a'...'z' => @intCast(c - 'a'),
        '0'...'9' => @intCast(26 + c - '0'),
        else => @intCast(36 + @as(u32, c) % 28),
    };
    return @as(u64, 1) << bit;
}

/// Case-insensitive substring search where `needle` is already lowercase.
/// Cheaper than std.ascii.findIgnoreCase for short haystacks like file paths,
/// which builds a 256-entry skip table on every call.
fn findLower(hay: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0) return 0;
    if (needle.len > hay.len) return null;
    const lo = needle[0];
    const up = ascii.toUpper(lo);
    const last = hay.len - needle.len;
    var i: usize = 0;
    while (i <= last) : (i += 1) {
        const c = hay[i];
        if (c != lo and c != up) continue;
        var j: usize = 1;
        while (j < needle.len and ascii.toLower(hay[i + j]) == needle[j]) j += 1;
        if (j == needle.len) return i;
    }
    return null;
}

fn isBoundary(ch: u8) bool {
    return switch (ch) {
        ' ', '-', '_', '.', '/', '(', '[', '+' => true,
        else => false,
    };
}

/// Case-insensitive subsequence match; returns a 0..30 quality score or null.
fn subsequence(hay: []const u8, tok: []const u8) ?i32 {
    if (tok.len < 2) return null;
    var ti: usize = 0;
    var gaps: i32 = 0;
    var last: ?usize = null;
    var first: usize = 0;
    for (hay, 0..) |ch, hi| {
        if (ascii.toLower(ch) == tok[ti]) {
            if (last) |l| {
                if (hi != l + 1 and !isBoundary(hay[hi - 1])) gaps += 1;
            } else first = hi;
            last = hi;
            ti += 1;
            if (ti == tok.len) break;
        }
    }
    if (ti != tok.len) return null;
    var s: i32 = 30 - @min(gaps * 4, 30);
    if (first == 0) s += 5;
    return s;
}

fn scoreToken(path: []const u8, name: []const u8, tok: []const u8, name_has_chars: bool) i32 {
    if (!name_has_chars) return scorePathOnly(path, tok);
    if (findLower(name, tok)) |pos| {
        var s: i32 = 100;
        if (pos == 0) {
            s += 60;
            if (name.len == tok.len) {
                s += 80;
            } else if (name[tok.len] == '.') {
                s += 60; // exact stem: "invoice" -> "invoice.pdf"
            }
        } else if (isBoundary(name[pos - 1])) {
            s += 30;
        }
        return s;
    }
    if (subsequence(name, tok)) |fs| return 30 + fs;
    return scorePathOnly(path, tok);
}

fn scorePathOnly(path: []const u8, tok: []const u8) i32 {
    if (findLower(path, tok)) |pos| {
        var s: i32 = 25;
        if (pos == 0 or isBoundary(path[pos - 1])) s += 10;
        return s;
    }
    return 0;
}

/// Returns 0 when the entry doesn't match every token.
/// `path_mask`/`name_mask` are `charMask` of the path and of its file name.
pub fn score(q: *const Query, path: []const u8, name_off: usize, path_mask: u64, name_mask: u64, mtime: i64, now: i64) i32 {
    if (path_mask & q.all_mask != q.all_mask) return 0;
    const name = path[name_off..];
    var total: i32 = 0;
    for (0..q.len) |i| {
        const m = q.masks[i];
        const s = scoreToken(path, name, q.token(i), name_mask & m == m);
        if (s == 0) return 0;
        total += s;
    }
    // Prefer shallow, visible, recently touched files.
    total -= @intCast(@min(path.len / 12, 20));
    if (std.mem.find(u8, path, "/.") != null) total -= 15;
    const age = now - mtime;
    if (age >= 0) {
        if (age < 30 * 86400) total += 10 else if (age < 365 * 86400) total += 4;
    }
    return @max(total, 1);
}

fn testScore(q: *const Query, path: []const u8, name_off: usize) i32 {
    return score(q, path, name_off, charMask(path), charMask(path[name_off..]), 0, 0);
}

test "query survives being copied" {
    const q = Query.parse("Foo  bar");
    const copy = q;
    try std.testing.expectEqualStrings("foo", copy.token(0));
    try std.testing.expectEqualStrings("bar", copy.token(1));
}

test "exact stem beats substring" {
    const q = Query.parse("invoice");
    const a = testScore(&q, "/d/invoice.pdf", 3);
    const b = testScore(&q, "/d/old-invoice-copy.pdf", 3);
    try std.testing.expect(a > b);
}

test "all tokens must match" {
    const q = Query.parse("tax 2024");
    try std.testing.expect(testScore(&q, "/docs/tax/return-2024.pdf", 10) > 0);
    try std.testing.expect(testScore(&q, "/docs/tax/return-2023.pdf", 10) == 0);
}

test "subsequence abbreviation" {
    const q = Query.parse("dsprd");
    try std.testing.expect(testScore(&q, "/x/desktop-search-prd.md", 3) > 0);
}

test "name match beats path-only match" {
    const q = Query.parse("seek");
    const name_hit = testScore(&q, "/a/seek.zig", 3);
    const path_hit = testScore(&q, "/seek/main.zig", 6);
    try std.testing.expect(name_hit > path_hit);
}

test "findLower" {
    try std.testing.expectEqual(@as(?usize, 3), findLower("my-README.md", "readme"));
    try std.testing.expectEqual(@as(?usize, null), findLower("read", "readme"));
    try std.testing.expectEqual(@as(?usize, 0), findLower("Seek", "seek"));
}

test "empty and whitespace-only queries are empty" {
    try std.testing.expect(Query.parse("").isEmpty());
    try std.testing.expect(Query.parse(" \t\r\n ").isEmpty());
}

test "tokens beyond max_tokens are ignored" {
    const q = Query.parse("a b c d e f g h i j");
    try std.testing.expectEqual(@as(usize, max_tokens), q.len);
    try std.testing.expectEqualStrings("h", q.token(max_tokens - 1));
}

test "an oversized query is truncated, not overflowed" {
    const raw: [2000]u8 = @splat('x');
    const q = Query.parse(&raw);
    try std.testing.expectEqual(@as(usize, 1), q.len);
    try std.testing.expectEqual(@as(usize, 512), q.token(0).len);
}

test "tokens are lowercased and split on any whitespace" {
    const q = Query.parse("  Tax\t2024\nPDF ");
    try std.testing.expectEqual(@as(usize, 3), q.len);
    try std.testing.expectEqualStrings("tax", q.token(0));
    try std.testing.expectEqualStrings("2024", q.token(1));
    try std.testing.expectEqualStrings("pdf", q.token(2));
}

test "charMask ignores case and is a superset for substrings" {
    try std.testing.expectEqual(charMask("ABC"), charMask("abc"));
    try std.testing.expectEqual(@as(u64, 0), charMask(""));
    const whole = charMask("invoice-2024.pdf");
    const part = charMask("2024");
    try std.testing.expectEqual(part, whole & part);
    // Non-alphanumerics must still set a bit, or a query like "-" could never be rejected.
    try std.testing.expect(charMask("-") != 0);
    try std.testing.expect(charMask("\xff") != 0);
}

test "mask rejection never hides a real match" {
    const paths = [_][]const u8{ "/a/Report Final.PDF", "/x/y-z_w.tar.gz", "/home/ünï/cødé.zig", "/p/.hidden/file" };
    const queries = [_][]const u8{ "report", "final pdf", "tar gz", "zig", "hidden", ".", "_w" };
    for (paths) |path| {
        const name_off = std.mem.lastIndexOfScalar(u8, path, '/').? + 1;
        for (queries) |raw| {
            const q = Query.parse(raw);
            const with_masks = score(&q, path, name_off, charMask(path), charMask(path[name_off..]), 0, 0);
            const all_ones = score(&q, path, name_off, std.math.maxInt(u64), std.math.maxInt(u64), 0, 0);
            // Real masks may only reject entries that the unmasked scorer would reject too.
            if (with_masks == 0) try std.testing.expectEqual(@as(i32, 0), all_ones);
        }
    }
}

test "subsequence needs in-order characters and at least two" {
    try std.testing.expectEqual(@as(?i32, null), subsequence("abc", "a"));
    try std.testing.expectEqual(@as(?i32, null), subsequence("abc", "ca"));
    try std.testing.expectEqual(@as(?i32, null), subsequence("abc", "abd"));
    try std.testing.expect(subsequence("abc", "ac") != null);
}

test "subsequence rewards a start match and penalises gaps" {
    const tight = subsequence("abcdef", "abc").?;
    const gappy = subsequence("axbxcx", "abc").?;
    try std.testing.expect(tight > gappy);
    const at_start = subsequence("abcd", "ab").?;
    const later = subsequence("xabcd", "ab").?;
    try std.testing.expect(at_start > later);
    // Hops across a word boundary are free: "ar" in "alpha-rho" costs nothing extra.
    try std.testing.expect(subsequence("alpha-rho", "ar").? >= subsequence("alphaxrho", "ar").?);
}

test "isBoundary" {
    for (" -_./([+") |ch| try std.testing.expect(isBoundary(ch));
    for ("aZ09") |ch| try std.testing.expect(!isBoundary(ch));
}

test "findLower edge cases" {
    try std.testing.expectEqual(@as(?usize, 0), findLower("anything", ""));
    try std.testing.expectEqual(@as(?usize, 0), findLower("", ""));
    try std.testing.expectEqual(@as(?usize, null), findLower("", "a"));
    try std.testing.expectEqual(@as(?usize, 0), findLower("abab", "ab")); // first occurrence wins
    try std.testing.expectEqual(@as(?usize, 2), findLower("aXab", "ab")); // restarts after a partial match
    try std.testing.expectEqual(@as(?usize, 2), findLower("xxAB", "ab")); // match at the very end
}

test "word-start match beats mid-word match" {
    const q = Query.parse("report");
    const word = testScore(&q, "/d/final-report.pdf", 3);
    const mid = testScore(&q, "/d/finalreport.pdf", 3);
    try std.testing.expect(word > mid);
}

test "hidden paths rank below visible ones" {
    const q = Query.parse("notes");
    const visible = testScore(&q, "/a/notes.txt", 3);
    const hidden = testScore(&q, "/.a/notes.txt", 4);
    try std.testing.expect(visible > hidden);
}

test "recently modified files rank higher" {
    const q = Query.parse("notes");
    const path = "/a/notes.txt";
    const now: i64 = 1_000_000_000;
    const day = 86400;
    const fresh = score(&q, path, 3, charMask(path), charMask(path[3..]), now - day, now);
    const mid = score(&q, path, 3, charMask(path), charMask(path[3..]), now - 100 * day, now);
    const old = score(&q, path, 3, charMask(path), charMask(path[3..]), now - 1000 * day, now);
    const future = score(&q, path, 3, charMask(path), charMask(path[3..]), now + day, now);
    try std.testing.expect(fresh > mid and mid > old);
    try std.testing.expectEqual(old, future); // clock skew gets no bonus
}

test "score is never negative for a match" {
    const q = Query.parse("a");
    const long = "/" ++ @as([400]u8, @splat('d')) ++ "/.a";
    try std.testing.expect(testScore(&q, long, long.len - 1) >= 1);
}
