/* Exercises libseek through its C API the same way the native app does. */
#include <seek.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <limits.h>
#include <unistd.h>
#include <pthread.h>
#include <sys/stat.h>

static uint64_t last_progress = 0;
static void on_progress(void *ctx, uint64_t n) { (void)ctx; last_progress = n; }

#define CHECK(cond) do { if (!(cond)) { fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond); return 1; } } while (0)

/* Searches on one thread while another re-scans: the concurrency contract in seek.h.
 * Meaningful under ThreadSanitizer (zig build test-tsan). */
static void *search_loop(void *arg) {
    seek_index *idx = arg;
    seek_result res[16];
    for (int i = 0; i < 300; i++) seek_search(idx, "index", res, 16);
    return NULL;
}

static int write_file(const char *dir, const char *name, const char *data) {
    char path[PATH_MAX + 64];
    snprintf(path, sizeof path, "%s/%s", dir, name);
    FILE *f = fopen(path, "w");
    if (!f) return -1;
    fputs(data, f);
    return fclose(f);
}

struct dups { int groups; int files; uint64_t first_size; int oldest_first; };
static void on_group(void *ctx, uint64_t size, const char *const *paths, const int64_t *mtimes, uint32_t count) {
    struct dups *d = ctx;
    if (d->groups++ == 0) d->first_size = size;
    d->files += (int)count;
    for (uint32_t i = 1; i < count; i++) if (mtimes[i] < mtimes[i - 1]) d->oldest_first = 0;
    (void)paths;
}
static int stop_at_once(void *ctx, uint64_t done, uint64_t total) { (void)ctx; (void)done; (void)total; return 1; }

int main(int argc, char **argv) {
    CHECK(argc == 2);
    char root[PATH_MAX];
    CHECK(realpath(argv[1], root) != NULL);

    char db[PATH_MAX + 32];
    snprintf(db, sizeof db, "/tmp/seek-capi-test-%d.db", (int)getpid());
    remove(db);

    seek_index *idx = seek_open(db);
    CHECK(idx != NULL);
    CHECK(seek_file_count(idx) == 0);

    int64_t n = seek_index_root(idx, root, on_progress, NULL);
    CHECK(n > 0);
    CHECK(last_progress == (uint64_t)n);
    CHECK(seek_root_count(idx) == 1);
    CHECK(seek_file_count(idx) == (uint64_t)n);

    seek_result res[16];
    int k = seek_search(idx, "index", res, 16);
    CHECK(k >= 1);
    CHECK(strcmp(res[0].path + res[0].name_offset, "Index.zig") == 0);
    CHECK(res[0].size > 0 && res[0].mtime > 0 && !res[0].is_dir);

    seek_filter only_folders = {.scope = 2};
    k = seek_search_filtered(idx, "src", &only_folders, res, 16);
    for (int i = 0; i < k; i++) CHECK(res[i].is_dir);
    seek_filter images = {.kind = 2};
    CHECK(seek_search_filtered(idx, "index", &images, res, 16) == 0);
    seek_filter big = {.min_size = 1};
    CHECK(seek_search_filtered(idx, "index", &big, res, 16) >= 1);

    CHECK(seek_search(idx, "index", res, 16) >= 1);
    uint64_t index_size = res[0].size;
    k = seek_find_same_size(idx, index_size, res, 16);
    CHECK(k >= 1);
    for (int i = 0; i < k; i++) CHECK(res[i].size == index_size && !res[i].is_dir);
    CHECK(seek_find_same_size(idx, 0, res, 16) == 0);

    /* Duplicates: two copies of one file, two of another, a same-size odd one out, an empty pair. */
    char dd[64];
    snprintf(dd, sizeof dd, "/tmp/seek-dups-%d", (int)getpid());
    CHECK(mkdir(dd, 0700) == 0);
    CHECK(write_file(dd, "a1.txt", "hello") == 0 && write_file(dd, "a2.txt", "hello") == 0);
    CHECK(write_file(dd, "b1.txt", "a much longer body") == 0 && write_file(dd, "b2.txt", "a much longer body") == 0);
    CHECK(write_file(dd, "odd.txt", "world") == 0 && write_file(dd, "e1", "") == 0 && write_file(dd, "e2", "") == 0);
    char dd_real[PATH_MAX];
    CHECK(realpath(dd, dd_real) != NULL);
    CHECK(seek_index_root(idx, dd_real, NULL, NULL) > 0);
    struct dups d = {.oldest_first = 1};
    CHECK(seek_find_duplicates(idx, 0, stop_at_once, on_group, &d) == -2); /* canceled while reading */
    CHECK(d.groups == 0);
    CHECK(seek_find_duplicates(idx, 0, NULL, on_group, &d) == 2);
    CHECK(d.groups == 2 && d.files == 4 && d.first_size == strlen("a much longer body") && d.oldest_first);
    CHECK(seek_find_duplicates(idx, 10, NULL, NULL, NULL) == 1); /* min_size drops the small pair */
    CHECK(seek_remove_root(idx, dd_real) == 0);
    {
        char cmd[PATH_MAX + 16];
        snprintf(cmd, sizeof cmd, "rm -rf '%s'", dd_real);
        CHECK(system(cmd) == 0);
    }

    CHECK(seek_search(idx, "no-such-file-xyzzy", res, 16) == 0);
    CHECK(seek_search(idx, "", res, 16) == 0);
    CHECK(seek_reindex_all(idx, NULL, NULL) == n);

    pthread_t searcher;
    CHECK(pthread_create(&searcher, NULL, search_loop, idx) == 0);
    for (int i = 0; i < 5; i++) CHECK(seek_reindex_all(idx, NULL, NULL) == n);
    pthread_join(searcher, NULL);

    /* The diagnostics log exists and records failures. */
    const char *log = seek_log_path(idx);
    CHECK(strlen(log) > 0 && access(log, R_OK) == 0);

    /* Failures are reported, not swallowed. */
    CHECK(strcmp(seek_last_error(idx), "") == 0);
    CHECK(seek_index_root(idx, "/definitely/not/a/real/folder", NULL, NULL) == -1);
    CHECK(strstr(seek_last_error(idx), "/definitely/not/a/real/folder") != NULL);
    CHECK(seek_add_root(idx, "/definitely/not/a/real/folder") == 0);
    CHECK(seek_reindex_all(idx, NULL, NULL) == n); /* the dead folder is skipped... */
    CHECK(strstr(seek_last_error(idx), "/definitely/not/a/real/folder") != NULL); /* ...and reported */
    CHECK(seek_remove_root(idx, "/definitely/not/a/real/folder") == 0);

    seek_close(idx);

    /* Reopen: the index persists. */
    idx = seek_open(db);
    CHECK(idx != NULL && seek_file_count(idx) == (uint64_t)n);
    seek_close(idx);
    remove(db);

    printf("capi_test: ok (%lld entries)\n", (long long)n);
    return 0;
}
