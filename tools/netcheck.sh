#!/usr/bin/env bash
# Checks the offline promise on the built binaries: they must not import networking functions
# or link networking frameworks, beyond the known dead code from Zig's standard library
# listed in tools/netcheck.baseline.
#
#   tools/netcheck.sh zig-out/Seek.app/Contents/MacOS/Seek zig-out/bin/seek
set -uo pipefail
cd "$(dirname "$0")/.."

NETWORKY='^_(socket|socketpair|connect|bind|listen|accept|accept4|send|sendto|sendmsg|sendfile|recv|recvfrom|recvmsg|getaddrinfo|freeaddrinfo|getnameinfo|gethostby[a-z]*|getpeername|getsockname|getsockopt|setsockopt|shutdown|if_nametoindex|inet_[a-z_]*|CFSocket[A-Za-z]*|CFStream[A-Za-z]*|SCNetwork[A-Za-z]*|nw_[a-z_]*)$|OBJC_CLASS_\$_(NSURLSession|NSURLConnection|NSURLDownload|NSURLRequest|NWConnection|NSNetService)'
FORBIDDEN_LIBS='CFNetwork|Network\.framework|WebKit|NetworkExtension|NetFS'

allowed=$(grep -vE '^\s*(#|$)' tools/netcheck.baseline)

fail=0
for bin in "$@"; do
  if [[ ! -f "$bin" ]]; then
    echo "netcheck: missing $bin (build it first)" >&2
    fail=1
    continue
  fi
  found=$(nm -u "$bin" 2>/dev/null | awk '{print $NF}' | grep -E "$NETWORKY" || true)
  extra=$(comm -23 <(sort -u <<<"$found") <(sort -u <<<"$allowed") | grep -v '^$' || true)
  libs=$(otool -L "$bin" 2>/dev/null | tail -n +2 | grep -E "$FORBIDDEN_LIBS" || true)
  if [[ -n "$extra$libs" ]]; then
    echo "netcheck: FAIL $bin"
    [[ -n "$extra" ]] && echo "  new networking imports: $(echo "$extra" | tr '\n' ' ')"
    [[ -n "$libs" ]] && echo "  networking frameworks:  $(echo "$libs" | tr '\n' ' ')"
    fail=1
  else
    echo "netcheck: ok   $bin"
  fi
done
exit $fail
