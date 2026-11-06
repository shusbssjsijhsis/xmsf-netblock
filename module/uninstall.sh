#!/system/bin/sh
# 卸载：停掉核对循环、删掉规则。规则本身不跨重启；这里是为了卸载后不重启也立刻干净。
DATA=${XNB_DATA:-/data/adb/xmsf_netblock}
if [ -r "$DATA/loop.pid" ]; then
  P="" S=""
  read -r P S X 2>/dev/null < "$DATA/loop.pid" || :
  case "$P" in
    ''|*[!0-9]*) ;;
    *)
      L=""
      IFS= read -r L 2>/dev/null < "/proc/$P/stat" || :
      L=${L##*) }
      set -- $L
      [ $# -ge 20 ] && [ "${20}" = "$S" ] && kill "$P" 2>/dev/null
      ;;
  esac
fi
rm -f "$DATA/loop.pid" 2>/dev/null
rmdir "$DATA/loop.lock" 2>/dev/null
for T in iptables ip6tables; do
  command -v "$T" >/dev/null 2>&1 || continue
  "$T" -w 5 -t filter -S OUTPUT 2>/dev/null | while IFS= read -r R; do
    case "$R" in "-A OUTPUT "*" -j xnb_out"|"-A OUTPUT "*" -j xnb_all") ;; *) continue;; esac
    set -- ${R#-A OUTPUT }
    "$T" -w 5 -t filter -D OUTPUT "$@" 2>/dev/null
  done
  for C in xnb_out xnb_all; do
    "$T" -w 5 -t filter -F "$C" 2>/dev/null
    "$T" -w 5 -t filter -X "$C" 2>/dev/null
  done
done
# 配置与计数在 /data/adb/xmsf_netblock，有意保留；不要了可手动删除。
exit 0
