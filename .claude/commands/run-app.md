---
description: Build, relaunch and sanity-check Seek.app
allowed-tools: Bash(zig build:*), Bash(pkill:*), Bash(open:*), Bash(pgrep:*), Bash(sleep:*), Bash(ps:*)
---
1. `zig build app` and report any compiler error or warning.
2. `pkill -x Seek; sleep 1; open zig-out/Seek.app; sleep 3`
3. Confirm it is still running with `pgrep -x Seek`, and report its RSS and CPU from `ps -o rss=,%cpu= -p <pid>`. If it exited, look at the newest file in `~/Library/Logs/DiagnosticReports` named `Seek-*.ips` and report the crashing frames.
Say plainly that you cannot see the UI; list what the user should look at.
