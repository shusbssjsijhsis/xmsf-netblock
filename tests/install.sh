#!/bin/bash
# Installer tests for module/customize.sh: fresh install, upgrade from a config without BLOCK_ALL,
# and a repeated install. Runs customize.sh the way a root manager does (sourced, with ui_print /
# abort / set_perm provided), under the given shell.
#
# Usage (as root, needs iptables for the capability probe):  bash tests/install.sh [shell]
set -u
T=$(cd "$(dirname "$0")" && pwd)
M=$(cd "$T/../module" && pwd)
SH=${1:-sh}
[ "$(id -u)" = 0 ] || { echo "run as root"; exit 2; }
W=$(mktemp -d "${TMPDIR:-/tmp}/xnb-install.XXXXXX")
FAILS=0
ok()   { echo "  ok   $*"; }
bad()  { echo "  FAIL $*"; FAILS=$((FAILS + 1)); }
want() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1: want [$3] got [$2]"; fi; }

printf '. "%s"\nMODPATH="%s"\n. "%s"\n' "$T/stub.sh" "$M" "$M/customize.sh" > "$W/inst.sh"
load() {  # load <data dir>: print the effective config
  XNB_DATA=$1 XNB_LIB=1 $SH -c '. "$0"; xnb_pick_tools; xnb_load; echo "PACKAGES=$PACKAGES HOSTS=$HOSTS BLOCK_ALL=$BLOCK_ALL"' "$M/xnb.sh"
}

echo "== [$SH] fresh install"
out=$(XNB_DATA=$W/fresh $SH "$W/inst.sh" 2>&1)
case "$out" in *ABORTED*) bad "installer aborted: $out";; *) ok "installer ran";; esac
want "config created from the default" "$(load "$W/fresh")" \
     "PACKAGES=com.xiaomi.xmsf HOSTS=hyperos.developer.xiaomi.com BLOCK_ALL=com.miui.guardprovider"
want "config is private" "$(stat -c %a "$W/fresh/config.conf")" "600"

echo "== [$SH] upgrade keeps the user's config and adds BLOCK_ALL once"
mkdir -p "$W/upg"
printf '# old config\nPACKAGES=com.xiaomi.xmsf\nHOSTS="hyperos.developer.xiaomi.com tracking.miui.com"\n' > "$W/upg/config.conf"
XNB_DATA=$W/upg $SH "$W/inst.sh" > "$W/upg.out" 2>&1
want "user's HOSTS kept, BLOCK_ALL added" "$(load "$W/upg")" \
     "PACKAGES=com.xiaomi.xmsf HOSTS=hyperos.developer.xiaomi.com tracking.miui.com BLOCK_ALL=com.miui.guardprovider"
XNB_DATA=$W/upg $SH "$W/inst.sh" > /dev/null 2>&1
want "a second install does not append again" "$(grep -c '^BLOCK_ALL=' "$W/upg/config.conf")" "1"
printf 'BLOCK_ALL=""\n' >> "$W/upg/config.conf"
XNB_DATA=$W/upg $SH "$W/inst.sh" > /dev/null 2>&1
want "a user's empty BLOCK_ALL is respected" "$(load "$W/upg" | sed 's/.*BLOCK_ALL=//')" ""

want "the probe leaves no chain behind" "$(iptables -w -S | grep -c xnb_probe)" "0"
echo "== [$SH] failures: $FAILS"
exit $FAILS
