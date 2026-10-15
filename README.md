# Seek

Instant, offline file search for macOS. Press Option+Space, type, press Return. Everything stays on your Mac.

A Zig core (`libseek`, C API in `include/seek.h`) with a native AppKit app and a CLI.

## Build

Needs the Xcode Command Line Tools and Zig 0.17.0.

```sh
zig build app -Doptimize=ReleaseFast   # zig-out/Seek.app
zig build check                        # format, lint, tests, offline check
```
