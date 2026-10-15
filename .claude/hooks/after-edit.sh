#!/usr/bin/env bash
# After Claude edits a file: format Zig, then run the project lint. Lint errors go back to
# Claude (exit 2) so it fixes them in the same turn.
set -uo pipefail
cd "${CLAUDE_PROJECT_DIR:-$(pwd)}" || exit 0

file=$(jq -r '.tool_input.file_path // empty' 2>/dev/null)
[[ -z "$file" || ! -f "$file" ]] && exit 0

case "$file" in
  *.zig) zig fmt "$file" >/dev/null 2>&1 || { echo "zig fmt failed on $file (syntax error?)" >&2; exit 2; } ;;
  *.m|*.h|*.c|*.sh) ;;
  *) exit 0 ;;
esac

out=$(tools/lint.sh 2>&1) || { echo "$out" | grep -E '^error|^lint:' >&2; exit 2; }
exit 0
