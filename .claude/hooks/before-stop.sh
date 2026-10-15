#!/usr/bin/env bash
# Before Claude finishes a turn: if source files changed, run `zig build check`. A failure is
# returned to Claude (exit 2) so it keeps working instead of declaring victory.
set -uo pipefail
cd "${CLAUDE_PROJECT_DIR:-$(pwd)}" || exit 0

input=$(cat)
# Already continuing because of this hook: don't loop forever.
[[ "$(jq -r '.stop_hook_active // false' <<<"$input" 2>/dev/null)" == "true" ]] && exit 0

# Only when code changed since the last commit (tracked changes or new files).
changed=$( { git diff --name-only HEAD; git ls-files --others --exclude-standard; } 2>/dev/null |
  grep -E '^(src/|macos/|tests/|include/|tools/|build\.zig)' || true)
[[ -z "$changed" ]] && exit 0

if out=$(zig build check 2>&1); then
  exit 0
fi
{
  echo "zig build check failed. Fix these before finishing:"
  echo "$out" | tail -40
} >&2
exit 2
