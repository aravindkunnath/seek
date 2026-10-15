#!/usr/bin/env bash
# Project lint rules that the compiler and `zig fmt` don't cover.
#
#   tools/lint.sh                 errors fail the run, warnings are only reported
#   LINT_VERBOSE=1 tools/lint.sh  list every warning, not just a count per rule
#   LINT_STRICT=1 tools/lint.sh   warnings fail too (the goal once the open issues are done)
#
# Silence one line with a trailing `lint:allow` comment (or `// lint:allow` in Zig/ObjC).
set -uo pipefail
cd "$(dirname "$0")/.."

ZIG=$(ls src/*.zig build.zig tests/*.zig 2>/dev/null)
OBJC=$(ls macos/*.m macos/*.h 2>/dev/null)
CSRC=$(ls tests/*.c include/*.h 2>/dev/null)
ALL="$ZIG $OBJC $CSRC"
LIB_ZIG=$(ls src/*.zig | grep -v '^src/main.zig$') # everything that ends up inside the app

errors=0
warnings=0
warn_summary=''

# rule <error|warn> <name> <message> <extended-regex> <files...>
rule() {
  local sev="$1" name="$2" msg="$3" re="$4"
  shift 4
  [[ $# -eq 0 ]] && return
  local hits
  hits=$(grep -HnE -- "$re" "$@" 2>/dev/null | grep -v 'lint:allow' || true)
  [[ -z "$hits" ]] && return
  local count
  count=$(grep -c . <<<"$hits")
  if [[ "$sev" == error ]]; then
    while IFS= read -r line; do printf 'error: %s [%s] %s\n' "$line" "$name" "$msg"; done <<<"$hits"
    errors=$((errors + count))
  else
    if [[ -n "${LINT_VERBOSE:-}" ]]; then
      while IFS= read -r line; do printf 'warn: %s [%s] %s\n' "$line" "$name" "$msg"; done <<<"$hits"
    fi
    warnings=$((warnings + count))
    warn_summary+="  $name: $count - $msg"$'\n'
  fi
}

# ---- privacy: the product promise is "no network calls"
rule error no-network "network code is not allowed (Seek is fully offline)" \
  'std\.net|std\.http|std\.Io\.net|NSURLSession|NSURLConnection|CFNetwork|CFSocket|NWConnection|getaddrinfo|gethostbyname|\bsocket\(' \
  $ZIG $OBJC
rule error no-urls "remote URLs are not allowed in source (use a comment-free placeholder)" \
  '"https?://' $ZIG $OBJC

# ---- the core must never take the host app down
rule error no-panic "don't abort the host app; return an error" '@panic\(|catch unreachable|std\.process\.exit' $LIB_ZIG
rule error no-debug-print "libseek must not print; return data or an error" 'std\.debug\.print' $LIB_ZIG
rule error unsafe-c "unbounded C string/format functions are not allowed" '\b(strcpy|strcat|sprintf|gets)\(' $OBJC $CSRC

# ---- hygiene
rule error todo-needs-issue "write TODO(#123) with a GitHub issue number" '(TODO|FIXME|XXX)([^(]|\([^#])' $ALL
rule error no-tabs "use spaces" $'\t' $ZIG $OBJC $CSRC
rule error trailing-space "trailing whitespace" '[[:space:]]+$' $ALL

for f in $ALL; do
  if [[ -s "$f" && -n "$(tail -c1 "$f")" ]]; then
    echo "error: $f: missing newline at end of file [eof-newline]"
    errors=$((errors + 1))
  fi
done

# ---- warnings: known debt, tracked by issues; they should trend to zero
rule warn swallowed-error "error is swallowed, so failures look like empty results" 'catch (\{\}|return (0|null|false)|continue|break|0)\b' $LIB_ZIG
rule warn deprecated-activate "activateIgnoringOtherApps is deprecated in macOS 14" 'activateIgnoringOtherApps' $OBJC
rule warn nslog "NSLog in app code: use os_log" 'NSLog\(' $OBJC

[[ -n "$warn_summary" && -z "${LINT_VERBOSE:-}" ]] && printf 'warnings (known debt):\n%s' "$warn_summary"
printf 'lint: %d error(s), %d warning(s)\n' "$errors" "$warnings"
if [[ $errors -gt 0 ]] || { [[ -n "${LINT_STRICT:-}" ]] && [[ $warnings -gt 0 ]]; }; then
  exit 1
fi
