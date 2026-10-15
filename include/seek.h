/* libseek: the Seek search core, exposed as a plain C API.
 * Implemented in Zig (src/capi.zig). Used by the CLI's tests and the native UI shells. */
#ifndef SEEK_H
#define SEEK_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct seek_index seek_index;

typedef struct {
    const char *path;      /* absolute, NUL-terminated; valid until the next seek_search on this handle */
    uint32_t name_offset;  /* path + name_offset is the file name */
    uint8_t is_dir;
    uint64_t size;         /* bytes; 0 for directories */
    int64_t mtime;         /* seconds since 1970 */
    int32_t score;         /* higher is better */
} seek_result;

/* Called from the indexing thread with a running count of entries seen. */
typedef void (*seek_progress_fn)(void *ctx, uint64_t files_seen);

/* Opens (or creates) the index. db_path may be NULL for the default location
 * ($SEEK_DB, else ~/Library/Application Support/Seek/seek.db on macOS). An older database is
 * upgraded in place; one written by a newer Seek is left untouched and NULL is returned. A damaged
 * one that no other process has open is renamed to seek.db.corrupt and replaced by an empty index
 * that keeps the saved folders and exclusions it could still read; seek_last_error then says so,
 * and the next rescan refills it. */
seek_index *seek_open(const char *db_path);
void seek_close(seek_index *idx);

/* Remembers a folder to index (absolute path). Returns 0 on success. */
int seek_add_root(seek_index *idx, const char *abs_path);
uint32_t seek_root_count(seek_index *idx);

/* Scans one folder, or every saved folder. Blocking: call from a background thread.
 * Returns entries seen, or -1 on error. */
int64_t seek_index_root(seek_index *idx, const char *abs_path, seek_progress_fn progress, void *ctx);
int64_t seek_reindex_all(seek_index *idx, seek_progress_fn progress, void *ctx);

/* Human-readable message for the most recent failure on this handle ("" if none), e.g.
 * "/Volumes/Backup: FileNotFound". Also set when seek_reindex_all skips a folder it couldn't scan
 * while still returning success. The pointer is valid until the next seek_last_error call on this
 * handle; call it from one thread at a time. Never NULL. */
const char *seek_last_error(seek_index *idx);

/* Path of the diagnostics log: a text file, one line per event (opens, scans, failures), kept next to
 * the database and rotated at 256 KB to seek.log.1. "" if the index has none. Valid until seek_close. */
const char *seek_log_path(seek_index *idx);

/* Number of entries in the in-memory index. */
uint64_t seek_file_count(seek_index *idx);

/* Ranked filename search. Writes up to max results into out and returns the count.
 * Safe to call while indexing runs on another thread; call from one search thread at a time. */
int seek_search(seek_index *idx, const char *query, seek_result *out, int max);

/* Narrows a search; zero in every field means no filtering. */
typedef struct {
    uint8_t scope;           /* 0 any, 1 files only, 2 folders only */
    uint8_t kind;            /* 0 any, 1 documents, 2 images, 3 audio, 4 video, 5 code, 6 archives */
    uint64_t min_size;       /* bytes; 0 = any */
    int64_t modified_after;  /* seconds since 1970; 0 = any time */
} seek_filter;

/* Like seek_search, restricted by filter (NULL = no filter). */
int seek_search_filtered(seek_index *idx, const char *query, const seek_filter *filter, seek_result *out, int max);

/* Files of exactly `size` bytes: duplicate candidates, to be confirmed by comparing content.
 * Shares its result buffer with seek_search (call from the same thread). */
int seek_find_same_size(seek_index *idx, uint64_t size, seek_result *out, int max);

/* Duplicate detection. Finds files with identical content (compared by SHA-256, so a match is
 * certain, not a guess) among the indexed files of at least min_size bytes; empty files, folders
 * and symlinks never count. Calls on_group once per group, the one that would free the most space
 * first: size is each file's size, and paths/mtimes hold count (>= 2) entries, oldest copy first,
 * valid only during the call. Returns the number of groups, -1 on failure (see seek_last_error),
 * or -2 if progress returned nonzero to cancel (hashes already computed are kept).
 * progress (may be NULL) is called after each file is read, with files done and total to read;
 * files hashed on an earlier run are not read again unless they changed.
 * Reads file contents, so it can take minutes on a large index: call it from a background thread.
 * Search and scanning keep working meanwhile, and it does not touch the seek_search result buffer.
 * Hard links to one file count once. Cancel via progress and wait for the call to return before
 * seek_close. */
typedef int (*seek_dup_progress_fn)(void *ctx, uint64_t done, uint64_t total);
typedef void (*seek_dup_group_fn)(void *ctx, uint64_t size, const char *const *paths, const int64_t *mtimes, uint32_t count);
int64_t seek_find_duplicates(seek_index *idx, uint64_t min_size, seek_dup_progress_fn progress,
                             seek_dup_group_fn on_group, void *ctx);

/* Folder and exclusion management. The list functions call cb once per item (n = entry count for
 * folders, 0 otherwise) and may block while a scan runs: call them from a background thread. */
typedef void (*seek_str_fn)(void *ctx, const char *s, uint64_t n);
void seek_list_roots(seek_index *idx, seek_str_fn cb, void *ctx);
int seek_remove_root(seek_index *idx, const char *abs_path);          /* forgets the folder and its entries */
int seek_add_exclude(seek_index *idx, const char *pattern);           /* name, "*" pattern, or absolute path */
int seek_remove_exclude(seek_index *idx, const char *pattern);
void seek_list_excludes(seek_index *idx, seek_str_fn cb, void *ctx);
void seek_list_default_excludes(seek_str_fn cb, void *ctx);           /* built-in, not editable */

#ifdef __cplusplus
}
#endif

#endif
