#!/system/bin/sh
ui_print "*******************************"
ui_print " XMSF 定向屏蔽 + 应用断网 v1.3"
ui_print " xmsf 只拦指定域名；BLOCK_ALL 里的应用整个断网"
ui_print "*******************************"

DATA=${XNB_DATA:-/data/adb/xmsf_netblock}
mkdir -p "$DATA"
chmod 0700 "$DATA"

# ---- 能力探测：owner 匹配 + string 匹配 + REJECT tcp-reset ----
# 规则只加在一条临时链里，不挂到 OUTPUT 上，对流量没有任何影响，探完即删。
command -v iptables >/dev/null 2>&1 || abort "! 找不到 iptables"
iptables -w 5 -t filter -N xnb_probe 2>/dev/null
PROBE_ERR=$(iptables -w 5 -t filter -A xnb_probe -p tcp -m owner --uid-owner 99999 \
  -m string --algo bm --icase --string probe.invalid -j REJECT --reject-with tcp-reset 2>&1)
PROBE_RC=$?
iptables -w 5 -t filter -F xnb_probe 2>/dev/null
iptables -w 5 -t filter -X xnb_probe 2>/dev/null
if [ "$PROBE_RC" -ne 0 ]; then
  ui_print "! 内核或 iptables 不支持所需的匹配：$PROBE_ERR"
  abort "! 本模块在这台设备上无法工作，已中止安装"
fi
ui_print "- 内核支持 owner + string + REJECT：可以工作"
if command -v ip6tables >/dev/null 2>&1; then
  ip6tables -w 5 -t filter -N xnb_probe 2>/dev/null
  if ip6tables -w 5 -t filter -A xnb_probe -p tcp -m owner --uid-owner 99999 \
       -m string --algo bm --icase --string probe.invalid -j REJECT --reject-with tcp-reset 2>/dev/null; then
    ui_print "- IPv6 同样支持"
  else
    ui_print "- IPv6 不支持，只拦 IPv4"
  fi
  ip6tables -w 5 -t filter -F xnb_probe 2>/dev/null
  ip6tables -w 5 -t filter -X xnb_probe 2>/dev/null
fi

# ---- 停掉旧版本的核对循环（升级时）----
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
      [ $# -ge 20 ] && [ "${20}" = "$S" ] && kill "$P" 2>/dev/null && ui_print "- 已停止旧的核对循环"
      ;;
  esac
  rm -f "$DATA/loop.pid"
  rmdir "$DATA/loop.lock" 2>/dev/null
fi

if [ ! -f "$DATA/config.conf" ]; then
  cp -f "$MODPATH/config.default.conf" "$DATA/config.conf"
  ui_print "- 已创建配置 $DATA/config.conf"
else
  ui_print "- 保留现有配置 $DATA/config.conf"
  # v1.3 新增的整个断网：旧配置里没有这一节就从默认配置补上（默认断安全守护）。
  if ! grep -q '^BLOCK_ALL=' "$DATA/config.conf" 2>/dev/null; then
    { printf '\n'; sed -n '/^# ---------- 整个断网/,$p' "$MODPATH/config.default.conf"; } >> "$DATA/config.conf"
    ui_print "- 配置里补上了整个断网：BLOCK_ALL=\"com.miui.guardprovider\"（不想断就改成空）"
  fi
fi
chmod 0600 "$DATA/config.conf"

set_perm_recursive "$MODPATH" 0 0 0755 0644
for F in xnb.sh service.sh action.sh uninstall.sh; do
  set_perm "$MODPATH/$F" 0 0 0755
done

ui_print "- 重启后生效。之后看状态："
ui_print "    su -c 'sh /data/adb/modules/xmsf_netblock/xnb.sh status'"
ui_print "- 点模块的“操作”可以随时停用 / 启用"
