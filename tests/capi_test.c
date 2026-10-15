/* Exercises libseek through its C API the same way the native app does. */
#include <seek.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <limits.h>
#include <unistd.h>
#include <pthread.h>

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

    CHECK(seek_search(idx, "no-such-file-xyzzy", res, 16) == 0);
    CHECK(seek_search(idx, "", res, 16) == 0);
    CHECK(seek_reindex_all(idx, NULL, NULL) == n);

    pthread_t searcher;
    CHECK(pthread_create(&searcher, NULL, search_loop, idx) == 0);
    for (int i = 0; i < 5; i++) CHECK(seek_reindex_all(idx, NULL, NULL) == n);
    pthread_join(searcher, NULL);

    seek_close(idx);

    /* Reopen: the index persists. */
    idx = seek_open(db);
    CHECK(idx != NULL && seek_file_count(idx) == (uint64_t)n);
    seek_close(idx);
    remove(db);

    printf("capi_test: ok (%lld entries)\n", (long long)n);
    return 0;
}
