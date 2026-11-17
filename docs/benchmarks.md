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
searches. Straight after loading it reads far lower, because macOS does not charge for the
snapshot's pages until they have been read.

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

2026-11-16, Apple M4 Pro (12 cores), 24 GB, macOS 27.0.1, internal SSD, 1,000,000 entries.

| What | Result | Budget |
|---|---|---|
| First scan | 10.5 to 11.5 s (about 90,000 entries/s) | none yet |
| Rescan, nothing changed | 10.2 s, 1,000,000 rows written | **not met** (0 rows) |
| Database size | 371 MB, plus an 8 MB write-ahead log | none yet |
| Open and load | 0.25 s | none yet |
| Search p50 / p99, 1 character | 2.8 ms / 3.5 ms | met |
| Search p50 / p99, 3 characters | 5.6 ms / 9.7 ms | met |
| Search p50 / p99, 8 characters | 2.4 ms / 5.5 ms | met |
| Search p50 / p99, several words | 2.7 ms / 7.2 ms | met |
| Idle memory | 182 MB | met, with 9% to spare |
| Peak memory, scan process | 79 MB | none yet |

## What the numbers say

- Search is comfortably inside its budget on this machine. A slower Mac with fewer cores has
  not been measured.
- A rescan costs as much as a first scan and rewrites every row. That is the cost the app pays
  every 15 minutes today, and what incremental updates (R1 in `architecture-fitness.md`) are
  meant to remove.
- Idle memory is close to the limit. Paths in this tree average 132 bytes (35,000 of the entries
  are folders, nested up to seven deep); a home folder with longer paths would go over. Storing a name and a parent instead of a full path (R2) is
  the known way down.
- The database is 371 MB for a million entries, about 370 bytes an entry, because each path is
  stored in the table and again in its unique index.
