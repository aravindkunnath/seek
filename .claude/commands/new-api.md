---
description: Checklist for adding or changing a function in the libseek C API
---
Adding or changing the C API for: $ARGUMENTS

Do all of these, then run `zig build check` (and `zig build test-tsan` if it touches shared state):
1. Core behavior in `src/Index.zig`, with a Zig `test` next to the existing ones.
2. The `export fn` in `src/capi.zig`: no panics, handle every error explicitly, document who frees what and which thread may call it.
3. The declaration and a comment in `include/seek.h` (mention threading and blocking).
4. A case in `tests/capi_test.c`.
5. If the app needs it, call it from `macos/SeekApp.m` off the main thread when it can block on a scan.
