#!/bin/bash
# Static checks, no root needed:
#   · every module script parses under each available POSIX shell (Android's sh is mksh; root
#     managers run module scripts under busybox ash);
#   · no temporary variable (_xx_name) is assigned in two different functions of xnb.sh. Shell
#     variables are global, so a helper that reuses its caller's variable silently changes it -
#     v1.1 lost the dual-app UID on redeploy exactly that way.
set -u
M=$(cd "$(dirname "$0")/../module" && pwd)
FAILS=0
shells=""
for s in dash mksh "busybox ash" "bash --posix"; do
  command -v "${s%% *}" >/dev/null 2>&1 && shells="$shells|$s"
done
[ -n "$shells" ] || { echo "no POSIX shell found"; exit 2; }
IFS='|'
for s in ${shells#|}; do
  unset IFS
  for f in "$M"/*.sh; do
    $s -n "$f" || { echo "FAIL [$s] syntax: ${f##*/}"; FAILS=$((FAILS + 1)); }
  done
  IFS='|'
done
unset IFS
list=${shells#|}
echo "syntax: checked with ${list//|/, }"

awk '
  /^[a-z_]+\(\) *\{/ { fn = $1; sub(/\(\).*/, "", fn); next }
  /^}/ { fn = "" }
  fn != "" {
    line = $0
    while (match(line, /(for[ \t]+_[a-z0-9_]+|(^|[ \t;({])_[a-z0-9_]+=)/)) {
      v = substr(line, RSTART, RLENGTH); line = substr(line, RSTART + RLENGTH)
      sub(/^for[ \t]+/, "", v); sub(/^[ \t;({]/, "", v); sub(/=$/, "", v)
      if (!((fn SUBSEP v) in seen)) { seen[fn, v] = 1; owners[v] = owners[v] " " fn; cnt[v]++ }
    }
  }
  END {
    bad = 0
    for (v in cnt) if (cnt[v] > 1) { print "FAIL shared temp variable " v ":" owners[v]; bad = 1 }
    if (!bad) print "temp variables: each one belongs to a single function"
    exit bad
  }' "$M/xnb.sh" || FAILS=$((FAILS + 1))

[ "$FAILS" = 0 ] && echo "static checks passed" || echo "static checks: $FAILS failure(s)"
exit "$FAILS"
