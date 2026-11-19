# Benchmarks and budgets

"Instant" is the product claim. This page says what that means in numbers, how to measure it,
and what was measured last.

## How to run

```sh
zig build bench                        # 1,000,000 entries
zig build bench -Dbench-entries=50000  # a smaller tree, for a quick look
zig build bench -Dbench-enforce        # fail the build when a budget is not met
zig build bench-clean                  # delete the tree and its database
```

The first run generates a real tree of empty files and folders under `.zig-cache/seek-bench`
(about 45 s and 400 MB for a million entries, database included) and reuses it afterwards. The
tree comes from a fixed seed, so two runs measure the same thing. The benchmark is always built
in ReleaseFast.

It runs as two processes so that memory is measured the way a user would see it:

1. `scan`: a first scan into an empty database, then a second scan with nothing changed.
2. `search`: opens that index in a fresh process, then runs each query 40 times.

Queries come in four groups: one character (the worst case, since almost no entry can be
rejected early), three characters, eight characters, and several words. Each group includes a
query that matches nothing.

"Idle memory" is the process's memory footprint (the figure Activity Monitor shows) after the
searches have run.

The benchmark covers the core only. It does not measure the app's own memory or drawing time.

## Budgets for 1.0, at 1,000,000 entries

| What | Budget |
|---|---|
| Search, 99th percentile, every query group | under 30 ms |
| Idle memory | under 200 MB |
| Rows written by a rescan when nothing changed | 0 |

These are the starting point suggested in `architecture-fitness.md`. They live in
`tools/bench.zig` (`budgets`); change them there and here together.

## Measured

Apple M4 Pro (12 cores), 24 GB, macOS 27.0.1, internal SSD, 1,000,000 entries. Scan times vary
by a second or two between runs.

| What | 2026-11-16, first measurement | 2026-11-16, incremental scans (#5) | Budget |
|---|---|---|---|
| First scan | 10.5 to 11.5 s | 8.7 to 9.8 s | none yet |
| Rescan, nothing changed | 10.2 s, 1,000,000 rows written | 7.1 to 8.1 s, 0 rows written | 0 rows: **met** |
| Database size | 371 MB | 354 MB | none yet |
| Open and load | 0.25 s | 0.31 s | none yet |
| Search p99, 1 character | 3.5 ms | 3.6 ms | met |
| Search p99, 3 characters | 9.7 ms | 9.5 ms | met |
| Search p99, 8 characters | 5.5 ms | 5.5 ms | met |
| Search p99, several words | 7.2 ms | 7.3 ms | met |
| Idle memory | 182 MB | 176 MB | met, with 12% to spare |
| Peak memory, scan process | not comparable (see below) | 220 MB | none yet |

The first measurement's scan process reported a 79 MB peak. That figure left out the snapshot:
the old loader's last step moved the snapshot to a right-sized block, and macOS did not charge
for those pages until something read them. The same effect made memory read 35 MB straight
after loading. Loading now sizes the snapshot before filling it, so the numbers are real from
the start.

Seek.app itself, opened on this index and left alone after its launch rescan, holds 195 MB:
the 176 MB snapshot plus about 19 MB of app.

## What the numbers say

- Search is comfortably inside its budget on this machine. A slower Mac with fewer cores has
  not been measured.
- A rescan that finds nothing changed now writes nothing and leaves the snapshot alone. What is
  left of its 7 to 8 seconds is walking the tree and asking the file system about each entry,
  which only a file watcher (#12) removes.
- Idle memory is close to the limit. Paths in this tree average 132 bytes (35,000 of the
  entries are folders, nested up to seven deep); a home folder with longer paths would go over.
  Storing a name and a parent instead of a full path (R2 in `architecture-fitness.md`) is the
  known way down.
- A first scan leaves the snapshot's buffers up to half again larger than they need to be,
  because they grow as entries arrive. Restarting sizes them exactly.
- The database is about 350 bytes an entry, because each path is stored in the table and again
  in its unique index.
