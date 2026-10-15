# Content search: FTS5 decisions

Status: proposal, backed by a measured spike (issue #23). Nothing here is implemented yet.

## What was measured

A corpus of 6,916 text files, 77 MB (system headers, docs, Python and Zig sources), indexed into
SQLite 3.45.1 with FTS5. Query times are for the top 50 hits ranked by `bm25`.

| Configuration | Index size | Build | Word | Phrase | Prefix |
|---|---|---|---|---|---|
| `unicode61`, text stored | 1.36x the text | 2.8 s | 0.9 ms | 3.0 ms | 3.2 ms |
| `unicode61`, **contentless** | **0.30x** | 1.5 s | 0.6 ms | 1.7 ms | 3.2 ms |
| `unicode61`, contentless, `detail=column` | 0.15x | 1.2 s | 0.5 ms | not supported | 2.0 ms |
| `trigram`, contentless | 2.03x | 12.3 s | 3.4 ms | 8.4 ms | 6.9 ms |

Also checked (`contentless_delete=1`): deleting and updating a row works and takes effect
immediately; `unicode61 remove_diacritics 2` matches `creme` to `Crème`; `snake_case` identifiers are
split into words, so `parse` finds `parse_query` and `"parse_query"` works as a phrase; camelCase is
not split.

## Decisions

1. **Tokenizer: `unicode61 remove_diacritics 2`.** Trigram gives substring matching but costs 7x the
   space of the contentless word index and 8x the build time. Filename search already covers
   substring and fuzzy matching; content search is for words and phrases.
2. **Contentless table with `contentless_delete=1`.** The index holds tokens only (about 30% of the
   text size). It cannot return text, so snippets come from re-reading the file at query time (see
   "File resolver"). Do not use `detail=column`: it loses phrase queries.
3. **`rowid` = `files.id`.** Search is `fts MATCH ? JOIN files ON id = rowid ORDER BY bm25(fts)`, so
   the existing filters (kind, size, date, folder) apply with ordinary SQL.
4. **Search cost is not the risk; indexing cost and size are.** Cap what is read:
   at most 1 MB of text per file (configurable), skip binaries (NUL in the first 4 KB), skip the same
   folders the filename index skips, and index at utility QoS so it never competes with typing.

## SQLite version (resolved: bundled)

`contentless_delete` needs SQLite 3.43.0 or newer. As far as I recall macOS 13 ships 3.39.x and
macOS 14 ships 3.43.x, and Seek's deployment target is 13.0 (`build.zig`). **Verify on a macOS 13
machine** (`select sqlite_version()`). If so, the options are:

- Bundle the SQLite amalgamation (one `.c` file, public domain). Same version everywhere, FTS5
  guaranteed, and the `trigram` and `contentless_delete` options never depend on the OS. Costs a
  bigger binary (about 1 MB) and a vendored file to update.
- Raise the deployment target to macOS 14.
- Fall back on older systems to a stored-content table (1.36x) and plain deletes.

Decision: SQLite is bundled (`vendor/sqlite`). Guard it with a startup check of `sqlite3_libversion_number()` and
`PRAGMA compile_options` containing `ENABLE_FTS5`, logged and reported through `seek_last_error`.

## File resolver and content indexer (next steps)

- **Resolver**: `path -> Extracted{ text, kind }` selected by extension and a content sniff. First
  extractors: plain text and source code. Later: PDF, docx, rtf via platform APIs in the app, never
  inside the core. Returns `error.Unsupported` for everything else, which is recorded, not retried.
- **State table**: `content(file_id, size, mtime_ns, extractor, status, error)`. A row is current
  while size and mtime match, the same rule as the duplicate-hash cache. Only stale rows are re-read.
- **Indexer**: a background worker that takes stale rows in batches, inside one transaction per
  batch, can be cancelled, and reports progress. Deleting a file removes its FTS row in the
  same transaction as the `files` row.
- **Snippets**: re-read the file, find the first matched token with the same tokenizer rules,
  and cut about 120 characters around it. If the file changed or vanished, return the hit without one.
- **Schema**: a new migration step (the migration list already exists) adds the `content` table and
  the FTS table. Existing databases upgrade in place; the first run backfills in the background.

## Proposed order

1. SQLite version decision above (and the bundled build if chosen).
2. FTS5 table, `content` state table, migration, with Zig tests (including delete and update).
3. Resolver with the plain-text extractor, size and binary limits, and tests on odd inputs
   (empty, huge, invalid UTF-8, symlink, unreadable).
4. Background indexer and `seek_search_content` in the C API, plus `seek find --content`.
5. Snippets, then the app UI.
