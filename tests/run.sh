#!/bin/bash
# End-to-end tests for xnb.sh on a Linux host, with real iptables/ip6tables rules and real sockets:
# uid resolution (no /data/user_de), fail-safe keep, host blocking by SNI and proxy CONNECT,
# whole-app blocking (BLOCK_ALL), the check loop, off/on and uninstall.
#
# Usage (as root):  bash tests/run.sh [shell]       shell: sh (default), dash, mksh, "busybox ash"
# Needs: iptables, ip6tables, setpriv (util-linux), python3.
#
# It adds and removes rules in the host's filter OUTPUT chain and, to simulate netd, flushes that
# chain. Run it in a throwaway VM or container. It refuses to start if OUTPUT already has rules
# (set XNB_TEST_FORCE=1 to override).
set -u
T=$(cd "$(dirname "$0")" && pwd)
X=${XNB:-$(cd "$T/../module" && pwd)/xnb.sh}
SH=${1:-sh}
OLD=$T
[ "$(id -u)" = 0 ] || { echo "run as root"; exit 2; }
for c in iptables ip6tables setpriv python3; do command -v "$c" >/dev/null || { echo "missing: $c"; exit 2; }; done
if [ "${XNB_TEST_FORCE:-0}" != 1 ] && [ "$(iptables -w -S OUTPUT | grep -vc '^-P ')" != 0 ]; then
  echo "filter OUTPUT is not empty on this host; these tests flush it. Use a throwaway VM/container"
  echo "or set XNB_TEST_FORCE=1."; exit 2
fi
W=$(mktemp -d "${TMPDIR:-/tmp}/xnb-test.XXXXXX")
FAILS=0
ok()   { echo "  ok   $*"; }
bad()  { echo "  FAIL $*"; FAILS=$((FAILS + 1)); }
want() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1: want [$3] got [$2]"; fi; }
has()  { if grep -qF -- "$3" <<<"$2"; then ok "$1"; else bad "$1: missing [$3] in:"; printf '%s\n' "$2" | sed 's/^/        /'; fi; }

# ---- fixtures (fresh per run) ----
F=$(mktemp -d "$W/fx.XXXXXX")
printf 'com.xiaomi.xmsf 65534 0 /data/user/0/com.xiaomi.xmsf platform:privapp 3003 0 33 1 @system\ncom.other.app 10777 0 /data/user/0/com.other.app default:privapp 3003\n' > "$F/pk.list"
printf 'com.miui.guardprovider 65532 0 /data/user/0/com.miui.guardprovider platform:privapp 3003\ncom.sys.shared 1000 0 /data/system platform 1000\n' >> "$F/pk.list"
mkdir -p "$F/users/0" "$F/users/999" "$F/users/abc" "$F/users/0999" "$F/users_empty" "$F/users10/0" "$F/users10/999"
: > "$F/users/0.xml"; : > "$F/users/999.xml"; : > "$F/users/userlist.xml"
: > "$F/users10/10.xml"; : > "$F/users10/userlist.xml"
export XNB_PKGLIST="$F/pk.list" XNB_USERS_DIR="$F/users" XNB_MODDIR=$(dirname "$X")

lib() {  # lib <data dir> <shell code>
  XNB_DATA=$1 XNB_LIB=1 $SH -c '. "$0"; xnb_pick_tools; '"$2" "$X" 2>&1
}
live() { iptables -w -S OUTPUT | awk '$NF == "xnb_out" { for (i = 3; i < NF; i++) if ($i == "--uid-owner") print $(i + 1) }' | sort -n | tr '\n' ' ' | sed 's/ $//'; }
chainn() { iptables -w -S xnb_out 2>/dev/null | grep -c '^-A xnb_out '; }
stoploop() {  # the loop that `on` spawns would otherwise keep running behind the next tests
  _p=$(awk '{print $1}' "$1/loop.pid" 2>/dev/null); [ -n "$_p" ] || return 0
  kill "$_p" 2>/dev/null; for _i in $(seq 30); do kill -0 "$_p" 2>/dev/null || break; sleep 0.1; done
}

echo "== [$SH] resolution"
D=$(mktemp -d "$W/d.XXXXXX")
want "users from dirs and .xml, junk ignored" "$(lib "$D" 'xnb_users; echo " rc=$?"')" "0 999 rc=0"
want "xml-only user counted"                "$(XNB_USERS_DIR=$F/users10 lib "$D" 'xnb_users')" "0 10 999"
want "empty users dir → 0, rc=1"           "$(XNB_USERS_DIR=$F/users_empty lib "$D" 'xnb_users; echo " rc=$?"')" "0 rc=1"
want "uids = users × appId"                 "$(lib "$D" 'xnb_load; xnb_uids; echo "$XNB_UIDS sure=$XNB_UIDS_SURE"')" "65534 99965534 sure=1"
want "multi-package"                        "$(lib "$D" 'xnb_load; PACKAGES="com.xiaomi.xmsf,com.other.app"; xnb_uids; echo "$XNB_UIDS"')" "10777 65534 99910777 99965534"
want "unsure when users unreadable"         "$(XNB_USERS_DIR=$F/users_empty lib "$D" 'xnb_load; xnb_uids; echo "$XNB_UIDS sure=$XNB_UIDS_SURE"')" "65534 sure=0"
want "missing package → rc 1 + reason"      "$(lib "$D" 'xnb_load; PACKAGES=no.such; xnb_uids; echo "rc=$? $XNB_UIDS_WHY"')" "rc=1 packages.list 里没有 no.such"
want "unreadable packages.list → rc 1"      "$(XNB_PKGLIST=$F/nope lib "$D" 'xnb_load; xnb_uids; echo "rc=$?"')" "rc=1"
printf '65534 99965534|hyperos.developer.xiaomi.com\n' > "$D/applied.sig"
want "legacy v1.1 sig accepted"             "$(lib "$D" 'xnb_load; xnb_sig_uids')" "65534 99965534"
printf '65534 99965534|hyperos.developer.xiaomi.com|com.xiaomi.xmsf\n' > "$D/applied.sig"
want "v1.2 sig accepted"                    "$(lib "$D" 'xnb_load; xnb_sig_uids')" "65534 99965534"
printf 'garbage;rm|x|com.xiaomi.xmsf\n' > "$D/applied.sig"
want "garbage sig ignored" "$(lib "$D" 'xnb_load; xnb_sig_uids; echo "rc=$?"')" "rc=1"
printf '65534 99965534|hyperos.developer.xiaomi.com|com.xiaomi.xmsf\n' > "$D/applied.sig"
want "sig for other packages ignored"       "$(lib "$D" 'xnb_load; PACKAGES=com.other.app; xnb_sig_uids; echo "rc=$?"')" "rc=1"

echo "== [$SH] cgroup escape"
printf '3:cpuset:/top-app\n0::/uid_10234/pid_5678\n' > "$F/cg.app"; printf '0::/\n' > "$F/cg.root"
mkdir -p "$F/cgroot"; : > "$F/cgroot/cgroup.procs"
r=$(XNB_SELFCG=$F/cg.app XNB_CGROOT=$F/cgroot lib "$D" 'xnb_leave_app_cgroup; echo "pid=$$"')
want "app cgroup → pid written to root cgroup.procs" "$(cat "$F/cgroot/cgroup.procs")" "${r#pid=}"
: > "$F/cgroot/cgroup.procs"
XNB_SELFCG=$F/cg.root XNB_CGROOT=$F/cgroot lib "$D" 'xnb_leave_app_cgroup' >/dev/null
want "root cgroup → nothing written" "$(cat "$F/cgroot/cgroup.procs")" ""
printf '0::/uid_0/pid_812\n' > "$F/cg.sys"
XNB_SELFCG=$F/cg.sys XNB_CGROOT=$F/cgroot lib "$D" 'xnb_leave_app_cgroup' >/dev/null
want "boot-started (uid_0 group) → not moved" "$(cat "$F/cgroot/cgroup.procs")" ""
printf '0::/uid_1000/pid_812\n' > "$F/cg.sys2"
XNB_SELFCG=$F/cg.sys2 XNB_CGROOT=$F/cgroot lib "$D" 'xnb_leave_app_cgroup' >/dev/null
want "system uid group → not moved" "$(cat "$F/cgroot/cgroup.procs")" ""
printf '0::/uid_99910234/pid_9\n' > "$F/cg.u999"
r=$(XNB_SELFCG=$F/cg.u999 XNB_CGROOT=$F/cgroot lib "$D" 'xnb_leave_app_cgroup; echo "pid=$$"')
want "app in another user → moved" "$(cat "$F/cgroot/cgroup.procs")" "${r#pid=}"

echo "== [$SH] live rules"
D=$(mktemp -d "$W/d.XXXXXX"); export XNB_DATA=$D
$SH "$X" on > "$D/on.out" 2>&1
has "on spawned the loop" "$(cat "$D/xnb.log")" "核对循环启动"
stoploop "$D"
want "on: both users' uids blocked" "$(live)" "65534 99965534"
want "on: one host rule" "$(chainn)" "1"
st=$($SH "$X" status)
has "status: enforced uids shown" "$st" "规则里在拦的 uid：65534 99965534"
has "status: enabled" "$st" "已启用，规则在位"
python3 -I "$OLD/sink.py" "$D/sink.log" > "$D/sink.out" 2>&1 & SP=$!
for i in $(seq 50); do grep -q ready "$D/sink.out" 2>/dev/null && break; sleep 0.1; done
for u in 65534 99965534; do
  out=$(setpriv --reuid=$u --regid=65534 --clear-groups python3 -I - < "$OLD/client.py" 2>&1 | tr '\n' '|')
  has "uid $u: TLS SNI hyperos reset"     "$out" "A tls hyperos -> reset"
  has "uid $u: TLS other passes"          "$out" "B tls other -> other:"
  has "uid $u: CONNECT hyperos reset"     "$out" "C connect hyperos -> reset"
  has "uid $u: CONNECT other passes"      "$out" "D connect other -> reply:HTTP/1.1 200"
  has "uid $u: mixed-case SNI reset"      "$out" "E tls HyperOS(mixed case) -> reset"
done
out=$(setpriv --reuid=65533 --regid=65533 --clear-groups python3 -I - < "$OLD/client.py" 2>&1 | tr '\n' '|')
has "other uid not affected" "$out" "C connect hyperos -> reply:HTTP/1.1 200"
sleep 1
want "server saw hyperos only from the non-target uid (A, C, E)" "$(grep -c 'hyperos' "$D/sink.log")" "3"
c=$(lib "$D" 'xnb_counts; echo $XNB_SUM')
want "6 blocked attempts counted" "$c" "6"

echo "== [$SH] fail-safe: target unresolvable (like Termux before v1.2)"
XNB_PKGLIST=$F/nope $SH "$X" apply > "$D/a1.out" 2>&1
want "apply with unreadable packages.list keeps rules" "$(live)" "65534 99965534"
XNB_PKGLIST=$F/nope $SH "$X" on > "$D/a2.out" 2>&1; stoploop "$D"
want "on with unreadable packages.list keeps rules" "$(live)" "65534 99965534"
has "status explains it" "$(XNB_PKGLIST=$F/nope $SH "$X" status)" "这次算不出目标 uid：读不到"
want "logged once" "$(grep -c '算不出目标 uid' "$D/xnb.log")" "1"
iptables -w -F OUTPUT
XNB_PKGLIST=$F/nope lib "$D" 'xnb_check' >/dev/null
want "netd-style wipe + unresolvable → restored from last deploy" "$(live)" "65534 99965534"
XNB_USERS_DIR=$F/users_empty $SH "$X" apply > /dev/null 2>&1
want "users unreadable → merged with last, never shrinks" "$(live)" "65534 99965534"
has "users-unreadable note logged" "$(cat "$D/xnb.log")" "读不到用户列表"
printf '65534 99965534|hyperos.developer.xiaomi.com\n' > "$D/applied.sig"
iptables -w -F OUTPUT
XNB_PKGLIST=$F/nope lib "$D" 'xnb_check' >/dev/null
want "legacy sig + unresolvable → restored" "$(live)" "65534 99965534"
c=$(lib "$D" 'xnb_counts; echo $(( $(xnb_read_int "$XNB_TOTAL") + XNB_SUM ))')
want "cumulative count kept across redeploys" "$c" "6"

echo "== [$SH] user changes without gaps"
XNB_USERS_DIR=$F/users10 $SH "$X" apply > /dev/null 2>&1
want "user 10 added" "$(live)" "65534 1065534 99965534"
$SH "$X" apply > /dev/null 2>&1
want "user 10 gone again" "$(live)" "65534 99965534"
iptables -w -I OUTPUT 1 -p tcp -m owner --uid-owner 65534 -j xnb_out
iptables -w -I OUTPUT 1 -m owner --uid-owner 65534 -j xnb_out
iptables -w -I OUTPUT 1 -p tcp -m owner --uid-owner 12345 -j xnb_out
$SH "$X" apply > /dev/null 2>&1
want "duplicates, old forms and stray uids pruned" "$(iptables -w -S OUTPUT | grep -c 'xnb_out')" "2"
want "standard jumps remain" "$(live)" "65534 99965534"
want "chain still has one host rule" "$(chainn)" "1"
printf 'HOSTS="hyperos.developer.xiaomi.com other.example.com"\n' > "$D/config.conf"
$SH "$X" apply > /dev/null 2>&1
want "host list change → 2 rules" "$(chainn)" "2"
out=$(setpriv --reuid=65534 --regid=65534 --clear-groups python3 -I - < "$OLD/client.py" 2>&1 | tr '\n' '|')
has "second host now blocked" "$out" "D connect other -> reset"
rm -f "$D/config.conf"
$SH "$X" apply > /dev/null 2>&1
want "back to 1 rule" "$(chainn)" "1"
printf 'PACKAGES=com.not.installed\n' > "$D/config.conf"
$SH "$X" apply > /dev/null 2>&1
want "PACKAGES changed to an uninstalled app: the old target's rules go" "$(live)" ""
has "status shows why" "$($SH "$X" status)" "packages.list 里没有 com.not.installed"
has "the removal is logged" "$(cat "$D/xnb.log")" "目标应用改成了 com.not.installed"
rm -f "$D/config.conf"
$SH "$X" apply > /dev/null 2>&1
want "back to xmsf" "$(live)" "65534 99965534"

echo "== [$SH] loop keeps rules even while unresolvable"
XNB_FAST_INTERVAL=1 XNB_FAST_ROUNDS=30 XNB_PKGLIST=$F/nope $SH "$X" loop < /dev/null > /dev/null 2>&1 &
for i in $(seq 30); do [ -s "$D/loop.pid" ] && break; sleep 0.1; done
has "test loop is the fast one" "$(tail -n 3 "$D/xnb.log")" "先每 1s"
for r in 1 2; do
  iptables -w -F OUTPUT
  for i in $(seq 40); do [ "$(live)" = "65534 99965534" ] && break; sleep 0.1; done
  want "wipe $r restored by loop" "$(live)" "65534 99965534"
done
read -r LP LS < "$D/loop.pid"; kill "$LP" 2>/dev/null
for i in $(seq 30); do [ -e "$D/loop.pid" ] || break; sleep 0.1; done
want "loop cleaned up pid file" "$([ -e "$D/loop.pid" ] && echo left || echo gone)" "gone"

echo "== [$SH] whole-app blocking (BLOCK_ALL)"
alive() { iptables -w -S OUTPUT | awk '$NF == "xnb_all" { for (i = 3; i < NF; i++) if ($i == "--uid-owner") print $(i + 1) }' | sort -n | tr '\n' ' ' | sed 's/ $//'; }
printf 'BLOCK_ALL="com.miui.guardprovider"\n' > "$D/config.conf"
$SH "$X" apply > /dev/null 2>&1
want "guardprovider's uids are cut off" "$(alive)" "65532 99965532"
want "xmsf's host rules untouched" "$(live)" "65534 99965534"
want "all-chain: tcp-reset + reject (v4)" "$(iptables -w -S xnb_all | grep -c '^-A xnb_all ')" "2"
want "all-chain on IPv6 too" "$(ip6tables -w -S xnb_all 2>/dev/null | grep -c '^-A xnb_all ')" "2"
has "the jump covers every protocol" "$(iptables -w -S OUTPUT)" "-A OUTPUT -m owner --uid-owner 65532 -j xnb_all"
for u in 65532 99965532; do
  want "uid $u: TCP refused, proxy refused, UDP not sent" "$(setpriv --reuid=$u --regid=65532 --clear-groups python3 -I - < "$T/allclient.py" 2>&1)" "tls=refused proxy=refused udp=eperm"
done
want "another uid still connects" "$(setpriv --reuid=65533 --regid=65533 --clear-groups python3 -I - < "$T/allclient.py" 2>&1)" "tls=connected proxy=connected udp=refused"
out=$(setpriv --reuid=65534 --regid=65534 --clear-groups python3 -I - < "$OLD/client.py" 2>&1 | tr '\n' '|')
has "xmsf: only the listed host is blocked" "$out" "D connect other -> reply:HTTP/1.1 200"
st=$($SH "$X" status)
has "status: block-all line" "$st" "整个断网：com.miui.guardprovider   规则里在断网的 uid：65532 99965532"
has "status: rejected packets" "$st" "被拒：IPv4 6 个包"
iptables -w -F OUTPUT
XNB_PKGLIST=$F/nope lib "$D" 'xnb_check' >/dev/null
want "netd-style wipe + unresolvable → both restored (all)" "$(alive)" "65532 99965532"
want "netd-style wipe + unresolvable → both restored (host)" "$(live)" "65534 99965534"
printf 'BLOCK_ALL="com.xiaomi.xmsf, com.miui.guardprovider,com.miui.guardprovider"\n' > "$D/config.conf"
$SH "$X" apply > /dev/null 2>&1
want "xmsf refused in BLOCK_ALL, duplicates folded" "$(alive)" "65532 99965532"
has "xmsf refusal logged" "$(cat "$D/xnb.log")" "com.xiaomi.xmsf 已忽略"
want "xmsf push path still open" "$(setpriv --reuid=65534 --regid=65534 --clear-groups python3 -I - < "$T/allclient.py" 2>&1)" "tls=connected proxy=connected udp=refused"
printf 'BLOCK_ALL="com.sys.shared"\n' > "$D/config.conf"
$SH "$X" apply > /dev/null 2>&1
want "system-uid-only BLOCK_ALL: old rules go, nothing new" "$(alive)" ""
want "never a rule for a system uid" "$(iptables -w -S OUTPUT | grep -c 'uid-owner 1000 ')" "0"
has "status explains the skip" "$($SH "$X" status)" "都是系统共享 UID"
printf 'BLOCK_ALL="com.sys.shared,com.miui.guardprovider"\n' > "$D/config.conf"
$SH "$X" apply > /dev/null 2>&1
want "mixed list: app uids cut, system uid skipped" "$(alive)" "65532 99965532"
has "skip noted in status" "$($SH "$X" status)" "已跳过：com.sys.shared（uid 1000）"
printf 'BLOCK_ALL="com.miui.guardprovider;reboot"\n' > "$D/config.conf"
$SH "$X" apply > /dev/null 2>&1
want "invalid BLOCK_ALL → nothing cut" "$(alive)" ""
printf 'BLOCK_ALL="com.miui.guardprovider"\n' > "$D/config.conf"
$SH "$X" apply > /dev/null 2>&1
want "valid again → cut again" "$(alive)" "65532 99965532"
printf '' > "$D/config.conf"
$SH "$X" apply > /dev/null 2>&1
want "BLOCK_ALL removed from config → chain gone" "$(iptables -w -S | grep -c xnb_all)" "0"
has "status: not configured" "$($SH "$X" status)" "整个断网：未配置"
printf 'BLOCK_ALL="com.miui.guardprovider"\n' > "$D/config.conf"
$SH "$X" apply > /dev/null 2>&1

echo "== [$SH] off / uninstall"
$SH "$X" off > /dev/null 2>&1
want "off removes everything" "$(iptables -w -S | grep -c 'xnb_out\|xnb_all')" "0"
want "guardprovider back online when off" "$(setpriv --reuid=65532 --regid=65532 --clear-groups python3 -I - < "$T/allclient.py" 2>&1)" "tls=connected proxy=connected udp=refused"
has "status off" "$($SH "$X" status)" "已停用"
$SH "$X" on > /dev/null 2>&1
want "on restores" "$(live)" "65534 99965534"
want "on restores block-all" "$(alive)" "65532 99965532"
stoploop "$D"
XNB_DATA=$D $SH "$(dirname "$X")/uninstall.sh"
want "uninstall removes everything" "$(iptables -w -S | grep -c 'xnb_out\|xnb_all')" "0"
want "uninstall leaves no IPv6 rules" "$(ip6tables -w -S 2>/dev/null | grep -c 'xnb_out\|xnb_all')" "0"
kill $SP 2>/dev/null
for i in $(seq 20); do pgrep -f "$X loop" >/dev/null || break; sleep 0.1; done
want "no loop left" "$(pgrep -fc "$X loop" || true)" "0"
echo "== [$SH] failures: $FAILS"
exit $FAILS
