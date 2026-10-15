---
description: Run the full quality harness and fix whatever fails
allowed-tools: Bash(zig build:*), Bash(tools/*), Read, Edit
---
Run `zig build check`. If anything fails, fix the cause (not the check: never loosen a lint rule, edit `tools/netcheck.baseline`, or add `lint:allow` just to pass) and rerun until it is green. If `$ARGUMENTS` contains "deep", run `zig build check-deep` instead. Finish with a short summary of what failed and what you changed.
