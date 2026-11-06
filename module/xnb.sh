#!/system/bin/sh
# XMSF 定向屏蔽 + 应用断网
#
# 一、定向屏蔽：只拦指定应用（默认小米服务框架）连指定域名（默认 hyperos.developer.xiaomi.com）。
# 原理：filter 表 OUTPUT 链里，按 socket 属主 UID 把目标应用的 TCP 包导进 xnb_out 链；链里按
# 明文主机名匹配。主机名在两个地方是明文：
#   · 直连 HTTPS：TLS ClientHello 的 SNI；
#   · 经系统 HTTP 代理（如 Clash Meta 的“附加 HTTP 代理”）：代理隧道开头的 "CONNECT 主机名:443"。
# 命中就 REJECT --reject-with tcp-reset：那个包不发出去，应用立刻收到连接重置，不会挂着等超时。
# 不碰 DNS、不改 hosts、不改 Clash 配置；别的应用、该应用的其它域名（推送等）都不受影响。
#
# 二、整个断网（v1.3）：BLOCK_ALL 里的应用，所有连接一律拒绝（导进 xnb_all 链：TCP 立即重置，
# 其它协议回“端口不可达”）。Wi-Fi、流量、VPN、经本机代理都算，连接发不出去。DNS 查询由系统
# （netd）代发，不受影响：域名还能解析，只是连不上。系统共享 UID（appId < 10000，例如 1000 由
# system_server 和一堆系统组件共用）的包不做——那会连系统一起断网；也不接受 com.xiaomi.xmsf
# （会断推送）。
#
# 用法：sh xnb.sh status|on|off|apply|loop
#   status  看状态与拦截次数        on/off  启用/停用（停用会立即删规则，持久）
#   apply   按当前配置重新部署      loop    开机即由 service.sh 拉起，核对规则
#
# 注意：shell 变量都是全局的。每个函数只用自己前缀的临时变量（_ck_、_ro_ …），
# 互相调用时不会改掉对方的值——v1.1 之前 xnb_rules_ok 的循环变量改掉了调用方的
# UID 列表，规则被清后重新部署时会漏掉应用双开那个 UID。
#
# v1.2：在 Termux 里 su（默认继承 Termux 的挂载命名空间）时，Android 的应用数据隔离让
# /data/user_de 只剩 Termux 自己的目录。v1.1 靠它判断哪些用户装了目标应用，于是在 Termux 里
# 算不出 UID，执行 on/apply 时还会因此把规则删掉。现在用户列表改读 /data/system/users（不受
# 隔离影响），并且算不出目标时一律保留现有规则、沿用上次部署的 UID，绝不因此删规则。

XNB_MODDIR=${XNB_MODDIR:-${0%/*}}
XNB_DATA=${XNB_DATA:-/data/adb/xmsf_netblock}
XNB_CONF="$XNB_DATA/config.conf"
XNB_OFF="$XNB_DATA/disabled"
XNB_LOG="$XNB_DATA/xnb.log"
XNB_SIG="$XNB_DATA/applied.sig"
XNB_ASIG="$XNB_DATA/applied_all.sig"
XNB_TOTAL="$XNB_DATA/blocked.total"
XNB_LIVE="$XNB_DATA/blocked.live"
XNB_LOCK="$XNB_DATA/loop.lock"
XNB_PIDF="$XNB_DATA/loop.pid"
XNB_NOTEF="$XNB_DATA/.note"
XNB_NOTEF_A="$XNB_DATA/.note.all"
XNB_NOTEF_C="$XNB_DATA/.note.cfg"
XNB_CHAIN=xnb_out
XNB_ACHAIN=xnb_all
XNB_HPRE="-A OUTPUT -p tcp -m owner --uid-owner "
XNB_APRE="-A OUTPUT -m owner --uid-owner "
XNB_PKGLIST=${XNB_PKGLIST:-/data/system/packages.list}
XNB_USERS_DIR=${XNB_USERS_DIR:-/data/system/users}
XNB_CGROOT=${XNB_CGROOT:-/sys/fs/cgroup}
XNB_INTERVAL=${XNB_INTERVAL:-600}
# 开机后的头 10 分钟每 10 秒核对一次：xmsf 开机后很快就会上传（实测在开机完成前后），
# 而 netd 初始化时可能清掉 OUTPUT 里的规则——这段时间里规则一旦丢了要马上补回。
XNB_FAST_INTERVAL=${XNB_FAST_INTERVAL:-10}
XNB_FAST_ROUNDS=${XNB_FAST_ROUNDS:-60}

mkdir -p "$XNB_DATA" 2>/dev/null
chmod 0700 "$XNB_DATA" 2>/dev/null

xnb_log() { printf '%s %s\n' "$(date '+%m-%d %H:%M:%S')" "$*" >> "$XNB_LOG" 2>/dev/null; }

# 同一句提醒只记一次（开机时核对循环每 10 秒跑一轮，不能刷屏）；只给文件不给话表示恢复正常。
xnb_note_f() {
  if [ -z "${2:-}" ]; then
    [ -e "$1" ] && rm -f "$1"
    return 0
  fi
  [ "$2" = "$(cat "$1" 2>/dev/null)" ] && return 0
  printf '%s\n' "$2" > "$1"
  xnb_log "$2"
}
xnb_note() { xnb_note_f "$XNB_NOTEF" "${1:-}"; }
xnb_note_all() { xnb_note_f "$XNB_NOTEF_A" "${1:-}"; }

xnb_rotate() {
  [ -f "$XNB_LOG" ] || return 0
  _rt_s=$(wc -c < "$XNB_LOG" 2>/dev/null | tr -d ' ')
  case "$_rt_s" in ''|*[!0-9]*) return 0;; esac
  [ "$_rt_s" -gt 131072 ] && mv -f "$XNB_LOG" "$XNB_LOG.1" 2>/dev/null
  return 0
}

xnb_pick_tools() {
  XNB_AWK=""
  if command -v awk >/dev/null 2>&1; then XNB_AWK=awk
  else
    for _pt_c in /data/adb/ksu/bin/busybox /data/adb/magisk/busybox /system/bin/busybox; do
      [ -x "$_pt_c" ] && { XNB_AWK="$_pt_c awk"; break; }
    done
  fi
  XNB_TIMEOUT=""
  if command -v timeout >/dev/null 2>&1; then XNB_TIMEOUT=timeout
  else
    for _pt_c in /data/adb/ksu/bin/busybox /data/adb/magisk/busybox /system/bin/busybox; do
      [ -x "$_pt_c" ] && { XNB_TIMEOUT="$_pt_c timeout"; break; }
    done
  fi
}

xnb_load() {
  PACKAGES=com.xiaomi.xmsf
  HOSTS="hyperos.developer.xiaomi.com"
  BLOCK_ALL=""
  [ -r "$XNB_CONF" ] && . "$XNB_CONF"
  case "$PACKAGES" in ''|*[!A-Za-z0-9._,\ ]*)
    xnb_log "PACKAGES 不合法（$PACKAGES），改用默认 com.xiaomi.xmsf"
    PACKAGES=com.xiaomi.xmsf;;
  esac
  _ld_hs=""
  for _ld_x in $HOSTS; do
    case "$_ld_x" in
      ''|.*|*.|*..*|*[!A-Za-z0-9.-]*) xnb_log "忽略不合法的域名：$_ld_x"; continue;;
    esac
    [ "${#_ld_x}" -le 100 ] || { xnb_log "忽略过长的域名：$_ld_x"; continue; }
    _ld_hs="$_ld_hs $_ld_x"
  done
  HOSTS=${_ld_hs# }
  # 整个断网的应用：只认包名字符；不合法就这次不做（宁可少断，不能断错）；xmsf 不接受。
  _ld_warn=""
  case "$BLOCK_ALL" in *[!A-Za-z0-9._,\ ]*)
    _ld_warn="BLOCK_ALL 不合法（$BLOCK_ALL），整个断网这次不做"
    BLOCK_ALL="";;
  esac
  _ld_ba="" _ld_ifs=$IFS
  IFS=', '
  for _ld_x in $BLOCK_ALL; do
    case "$_ld_x" in
      '') continue;;
      com.xiaomi.xmsf) _ld_warn="BLOCK_ALL 里的 com.xiaomi.xmsf 已忽略：整个断网会断掉推送"; continue;;
    esac
    case " $_ld_ba " in *" $_ld_x "*) ;; *) _ld_ba="$_ld_ba $_ld_x";; esac
  done
  IFS=$_ld_ifs
  BLOCK_ALL=${_ld_ba# }
  xnb_note_f "$XNB_NOTEF_C" "$_ld_warn"
}

# 用户列表：/data/system/users 下的 <数字>/ 目录与 <数字>.xml（主用户 0、应用双开 999……）。
# 这个目录不受应用数据隔离影响，在 Termux 里 su 也看得全。读不到时按只有用户 0 算并返回 1。
xnb_users() {
  _us_out=""
  for _us_e in "$XNB_USERS_DIR"/[0-9]*; do
    [ -e "$_us_e" ] || continue
    _us_n=${_us_e##*/}
    _us_n=${_us_n%.xml}
    case "$_us_n" in 0) ;; ''|0*|*[!0-9]*) continue;; esac
    case " $_us_out " in *" $_us_n "*) ;; *) _us_out="$_us_out $_us_n";; esac
  done
  [ -n "$_us_out" ] || { printf '0'; return 1; }
  printf '%s' "${_us_out# }"
}

# 包名列表 → UID（每个用户 × packages.list 里的 appId；UID = 用户号 × 100000 + appId）。
# 不判断“这个用户装没装”：没装的用户里不会有那个 UID 的进程，多一条规则什么也不拦。
# 系统共享 UID（appId < 10000）的包跳过，记在 XR_SKIP。结果放在 XR_UIDS；读不到用户列表、
# 只按用户 0 算时 XR_SURE=0；算不出时原因在 XR_WHY。直接调用，别放进 $( )。
xnb_resolve() {
  XR_UIDS="" XR_SURE=1 XR_WHY="" XR_SKIP=""
  [ -n "${1:-}" ] || { XR_WHY="没有指定应用"; return 1; }
  [ -r "$XNB_PKGLIST" ] || { XR_WHY="读不到 $XNB_PKGLIST"; return 1; }
  _rs_pk=$(printf '%s' "$1" | tr ',' ' ')
  _rs_ids=$($XNB_AWK -v want=" $_rs_pk " 'index(want, " " $1 " ") && $2 ~ /^[1-9][0-9]*$/ { print $1 ":" $2 }' \
         "$XNB_PKGLIST" 2>/dev/null)
  _rs_ok=""
  for _rs_e in $_rs_ids; do
    _rs_a=${_rs_e##*:}
    if [ "$_rs_a" -lt 10000 ]; then
      XR_SKIP="$XR_SKIP ${_rs_e%:*}（uid $_rs_a）"
      continue
    fi
    _rs_ok="$_rs_ok $_rs_a"
  done
  XR_SKIP=${XR_SKIP# }
  if [ -z "$_rs_ok" ]; then
    if [ -n "$XR_SKIP" ]; then XR_WHY="都是系统共享 UID，不能按应用拦：$XR_SKIP"
    else XR_WHY="packages.list 里没有 $1"; fi
    return 1
  fi
  _rs_users=$(xnb_users) || XR_SURE=0
  _rs_out=""
  for _rs_a in $_rs_ok; do
    for _rs_u in $_rs_users; do
      _rs_out="$_rs_out $((_rs_u * 100000 + _rs_a))"
    done
  done
  _rs_out=$(printf '%s\n' $_rs_out | sort -n -u | tr '\n' ' ')
  XR_UIDS=${_rs_out% }
  [ -n "$XR_UIDS" ] || { XR_WHY="没有算出 UID"; return 1; }
  return 0
}

# 定向屏蔽的目标 UID（PACKAGES）。结果放在 XNB_UIDS / XNB_UIDS_SURE / XNB_UIDS_WHY。
xnb_uids() {
  xnb_resolve "$PACKAGES"
  _ui_rc=$?
  XNB_UIDS=$XR_UIDS XNB_UIDS_SURE=$XR_SURE XNB_UIDS_WHY=$XR_WHY
  return $_ui_rc
}

# 上次成功部署的定向屏蔽 UID（applied.sig 第一段）。目标应用改过就不算数；v1.1 的旧格式没记应用，照样认。
# 模式里的 | 必须加引号：mksh（Android 的 /system/bin/sh）把裸的 | 当成“或”。
xnb_sig_uids() {
  _sg_l=$(cat "$XNB_SIG" 2>/dev/null)
  _sg_u=${_sg_l%%"|"*}
  case "$_sg_l" in *"|"*"|"*) _sg_p=${_sg_l##*"|"};; *) _sg_p=$PACKAGES;; esac
  [ "$_sg_p" = "$PACKAGES" ] || return 1
  [ -n "$_sg_u" ] || return 1
  for _sg_w in $_sg_u; do
    case "$_sg_w" in ''|*[!0-9]*) return 1;; esac
  done
  printf '%s' "$_sg_u"
}

# 上次成功部署的整个断网 UID（applied_all.sig：“UID|应用”）。应用列表改过就不算数。
xnb_sig_auids() {
  _sa_l=$(cat "$XNB_ASIG" 2>/dev/null)
  case "$_sa_l" in *"|"*) ;; *) return 1;; esac
  _sa_u=${_sa_l%%"|"*}
  [ "${_sa_l#*"|"}" = "$BLOCK_ALL" ] || return 1
  [ -n "$_sa_u" ] || return 1
  for _sa_w in $_sa_u; do
    case "$_sa_w" in ''|*[!0-9]*) return 1;; esac
  done
  printf '%s' "$_sa_u"
}

# 上次部署时记下的应用列表（没有记录返回 1）。v1.1 的旧格式没记应用，按当前 PACKAGES 算。
xnb_sig_pkgs() {
  _sp_l=$(cat "$XNB_SIG" 2>/dev/null)
  [ -n "$_sp_l" ] || return 1
  case "$_sp_l" in *"|"*"|"*) printf '%s' "${_sp_l##*"|"}";; *) printf '%s' "$PACKAGES";; esac
}
xnb_asig_pkgs() {
  _as_l=$(cat "$XNB_ASIG" 2>/dev/null)
  case "$_as_l" in *"|"*) printf '%s' "${_as_l#*"|"}";; *) return 1;; esac
}

xnb_bin() { case "$1" in 4) command -v iptables 2>/dev/null;; 6) command -v ip6tables 2>/dev/null;; esac; }

# xnb_ipt <4|6> <参数…>：等 xtables 锁最多 5 秒，整体 20 秒超时；错误信息留在 XNB_ERR。
XNB_ERR=""
xnb_ipt() {
  _ip_f=$1; shift
  _ip_b=$(xnb_bin "$_ip_f") || return 127
  _ip_e="$XNB_DATA/.err.$$"
  if [ -n "$XNB_TIMEOUT" ]; then
    $XNB_TIMEOUT 20 "$_ip_b" -w 5 "$@" 2> "$_ip_e"
  else
    "$_ip_b" -w 5 "$@" 2> "$_ip_e"
  fi
  _ip_rc=$?
  XNB_ERR=$(head -n 1 "$_ip_e" 2>/dev/null)
  rm -f "$_ip_e"
  return $_ip_rc
}

# xnb_unjump <4|6> [要保留的 UID] [链] [标准写法前缀]：删掉 OUTPUT 里跳到这条链（默认 xnb_out）
# 的规则。每个要保留的 UID 只留一条标准写法的跳转，其余（别的 UID、重复的、旧版本的写法）都删。
xnb_unjump() {
  _uj_f=$1 _uj_keep=" ${2:-} " _uj_seen=" "
  _uj_ch=${3:-$XNB_CHAIN} _uj_pre=${4:-$XNB_HPRE}
  _uj_rl="$XNB_DATA/.rules.$$"
  xnb_ipt "$_uj_f" -t filter -S OUTPUT > "$_uj_rl" || { rm -f "$_uj_rl"; return 0; }
  while IFS= read -r _uj_l; do
    case "$_uj_l" in "-A OUTPUT "*" -j $_uj_ch") ;; *) continue;; esac
    _uj_u=${_uj_l#"$_uj_pre"}
    _uj_u=${_uj_u%" -j $_uj_ch"}
    case "$_uj_u" in
      ''|*[!0-9]*) ;;
      *) case "$_uj_keep" in
           *" $_uj_u "*) case "$_uj_seen" in
                           *" $_uj_u "*) ;;
                           *) _uj_seen="$_uj_seen$_uj_u "; continue;;
                         esac;;
         esac;;
    esac
    # shellcheck disable=SC2086
    set -- ${_uj_l#-A OUTPUT }
    xnb_ipt "$_uj_f" -t filter -D OUTPUT "$@"
  done < "$_uj_rl"
  rm -f "$_uj_rl"
  return 0
}

# 当前计数：xnb_out 里每条规则的命中包数（一次被拦的连接 = 1 个包）。
# 结果放在 XNB_SUM（总数）与 XNB_DETAIL（逐条明细）里——直接调用，别放进 $( )，
# 否则子 shell 里的赋值带不回来。
xnb_counts() {
  XNB_DETAIL="" _cn_sum=0
  for _cn_f in 4 6; do
    xnb_bin "$_cn_f" >/dev/null 2>&1 || continue
    _cn_tmp="$XNB_DATA/.cnt.$$"
    xnb_ipt "$_cn_f" -t filter -L "$XNB_CHAIN" -v -n -x > "$_cn_tmp" || { rm -f "$_cn_tmp"; continue; }
    _cn_d=$($XNB_AWK -v fam="$_cn_f" '
      NR > 2 && $1 ~ /^[0-9]+$/ {
        h = "?"
        if (match($0, /"[^"]*"/)) h = substr($0, RSTART + 1, RLENGTH - 2)
        printf "  IPv%s  %-36s %s\n", fam, h, $1
      }' "$_cn_tmp")
    _cn_s=$($XNB_AWK 'NR > 2 && $1 ~ /^[0-9]+$/ { s += $1 } END { print s + 0 }' "$_cn_tmp")
    rm -f "$_cn_tmp"
    XNB_DETAIL="$XNB_DETAIL${_cn_d:+$_cn_d
}"
    _cn_sum=$((_cn_sum + ${_cn_s:-0}))
  done
  XNB_SUM=$_cn_sum
}

# 整个断网被拒的包数（本次部署以来）：XNB_A4 / XNB_A6。直接调用。
xnb_counts_all() {
  XNB_A4=0 XNB_A6=0
  for _ca_f in 4 6; do
    xnb_bin "$_ca_f" >/dev/null 2>&1 || continue
    _ca_n=$(xnb_ipt "$_ca_f" -t filter -L "$XNB_ACHAIN" -v -n -x | $XNB_AWK 'NR > 2 && $1 ~ /^[0-9]+$/ { s += $1 } END { print s + 0 }')
    case "$_ca_n" in ''|*[!0-9]*) _ca_n=0;; esac
    if [ "$_ca_f" = 4 ]; then XNB_A4=$_ca_n; else XNB_A6=$_ca_n; fi
  done
}

xnb_read_int() { _ri_v=$(cat "$1" 2>/dev/null); case "$_ri_v" in ''|*[!0-9]*) printf 0;; *) printf '%s' "$_ri_v";; esac; }

# 重新部署前把这一轮规则的计数并入累计（规则一冲就清零，重启也会清零）。
xnb_bank() {
  xnb_counts
  _bk_now=$XNB_SUM
  _bk_last=$(xnb_read_int "$XNB_LIVE")
  [ "$_bk_last" -gt "$_bk_now" ] && _bk_now=$_bk_last
  _bk_tot=$(xnb_read_int "$XNB_TOTAL")
  printf '%s\n' $((_bk_tot + _bk_now)) > "$XNB_TOTAL"
  printf '0\n' > "$XNB_LIVE"
}

# 只删整个断网那部分（xnb_all 链与跳到它的跳转）。
xnb_remove_all() {
  for _ra_f in 4 6; do
    xnb_bin "$_ra_f" >/dev/null 2>&1 || continue
    xnb_unjump "$_ra_f" "" "$XNB_ACHAIN" "$XNB_APRE"
    xnb_ipt "$_ra_f" -t filter -F "$XNB_ACHAIN"
    xnb_ipt "$_ra_f" -t filter -X "$XNB_ACHAIN"
  done
  rm -f "$XNB_ASIG"
  [ -n "${1:-}" ] && xnb_log "整个断网的规则已删除：$1"
  return 0
}

# 只删定向屏蔽那部分（xnb_out 链与跳到它的跳转），计数先并入累计。
xnb_remove_host() {
  xnb_bank
  for _rh_f in 4 6; do
    xnb_bin "$_rh_f" >/dev/null 2>&1 || continue
    xnb_unjump "$_rh_f"
    xnb_ipt "$_rh_f" -t filter -F "$XNB_CHAIN"
    xnb_ipt "$_rh_f" -t filter -X "$XNB_CHAIN"
  done
  rm -f "$XNB_SIG"
  return 0
}

xnb_remove() {
  xnb_remove_host
  xnb_remove_all
  [ -n "${1:-}" ] && xnb_log "规则已删除：$1"
  return 0
}

xnb_apply_fam() {
  _af_f=$1 _af_uids=$2
  xnb_ipt "$_af_f" -t filter -N "$XNB_CHAIN"    # 链已存在时报错，不要紧
  # 新的域名规则先加在链尾，再从链头删掉原有的那几条：重新部署时链里始终有规则，不留空档。
  _af_old=$(xnb_ipt "$_af_f" -t filter -S "$XNB_CHAIN" | grep -c "^-A $XNB_CHAIN ")
  case "$_af_old" in ''|*[!0-9]*) _af_old=0;; esac
  for _af_h in $HOSTS; do
    xnb_ipt "$_af_f" -t filter -A "$XNB_CHAIN" -p tcp -m string --algo bm --icase --string "$_af_h" \
      -j REJECT --reject-with tcp-reset \
      || { XNB_WHY="string/REJECT 规则添加失败：$XNB_ERR"; return 1; }
  done
  while [ "$_af_old" -gt 0 ]; do
    xnb_ipt "$_af_f" -t filter -D "$XNB_CHAIN" 1 || { XNB_WHY="删除旧的域名规则失败：$XNB_ERR"; return 1; }
    _af_old=$((_af_old - 1))
  done
  # 跳转也是先补上缺的、再删多余的：已经在拦的 UID 不会有空档。
  for _af_u in $_af_uids; do
    xnb_ipt "$_af_f" -t filter -C OUTPUT -p tcp -m owner --uid-owner "$_af_u" -j "$XNB_CHAIN" && continue
    xnb_ipt "$_af_f" -t filter -I OUTPUT 1 -p tcp -m owner --uid-owner "$_af_u" -j "$XNB_CHAIN" \
      || { XNB_WHY="owner 跳转添加失败：$XNB_ERR"; return 1; }
  done
  xnb_unjump "$_af_f" "$_af_uids"
  return 0
}

xnb_apply() {
  _ap_uids=$1
  XNB_WHY=""
  [ -n "$HOSTS" ] || { XNB_WHY="HOSTS 为空"; return 1; }
  xnb_bin 4 >/dev/null 2>&1 || { XNB_WHY="找不到 iptables"; return 1; }
  xnb_bank
  if ! xnb_apply_fam 4 "$_ap_uids"; then
    # 不删已经加上的部分：每条规则都是“命中域名才重置”，留着只会少拦、不会多拦；下次核对再补齐。
    xnb_log "部署失败（IPv4）：$XNB_WHY；已加上的规则保留，下次核对重试"
    return 1
  fi
  if xnb_bin 6 >/dev/null 2>&1 && ! xnb_apply_fam 6 "$_ap_uids"; then
    xnb_log "IPv6 规则失败，只拦 IPv4：$XNB_WHY"
  fi
  printf '%s|%s|%s\n' "$_ap_uids" "$HOSTS" "$PACKAGES" > "$XNB_SIG"
  xnb_log "已部署：uid=$_ap_uids 域名=$HOSTS"
  return 0
}

# 整个断网：xnb_all 链里两条——TCP 立即重置、其它协议回“端口不可达”；OUTPUT 里按 UID 跳过来
# （不限协议）。和定向屏蔽一样先加新的、再删旧的，不留空档。
xnb_apply_all_fam() {
  _al_f=$1 _al_uids=$2
  xnb_ipt "$_al_f" -t filter -N "$XNB_ACHAIN"
  _al_old=$(xnb_ipt "$_al_f" -t filter -S "$XNB_ACHAIN" | grep -c "^-A $XNB_ACHAIN ")
  case "$_al_old" in ''|*[!0-9]*) _al_old=0;; esac
  xnb_ipt "$_al_f" -t filter -A "$XNB_ACHAIN" -p tcp -j REJECT --reject-with tcp-reset \
    || { XNB_WHY="REJECT（tcp-reset）规则添加失败：$XNB_ERR"; return 1; }
  xnb_ipt "$_al_f" -t filter -A "$XNB_ACHAIN" -j REJECT \
    || { XNB_WHY="REJECT 规则添加失败：$XNB_ERR"; return 1; }
  while [ "$_al_old" -gt 0 ]; do
    xnb_ipt "$_al_f" -t filter -D "$XNB_ACHAIN" 1 || { XNB_WHY="删除旧的断网规则失败：$XNB_ERR"; return 1; }
    _al_old=$((_al_old - 1))
  done
  for _al_u in $_al_uids; do
    xnb_ipt "$_al_f" -t filter -C OUTPUT -m owner --uid-owner "$_al_u" -j "$XNB_ACHAIN" && continue
    xnb_ipt "$_al_f" -t filter -I OUTPUT 1 -m owner --uid-owner "$_al_u" -j "$XNB_ACHAIN" \
      || { XNB_WHY="owner 跳转添加失败：$XNB_ERR"; return 1; }
  done
  xnb_unjump "$_al_f" "$_al_uids" "$XNB_ACHAIN" "$XNB_APRE"
  return 0
}

xnb_apply_all() {
  _aa_uids=$1
  XNB_WHY=""
  xnb_bin 4 >/dev/null 2>&1 || { XNB_WHY="找不到 iptables"; return 1; }
  if ! xnb_apply_all_fam 4 "$_aa_uids"; then
    xnb_log "整个断网部署失败（IPv4）：$XNB_WHY；已加上的规则保留，下次核对重试"
    return 1
  fi
  if xnb_bin 6 >/dev/null 2>&1 && ! xnb_apply_all_fam 6 "$_aa_uids"; then
    xnb_log "整个断网的 IPv6 规则失败，只断 IPv4：$XNB_WHY"
  fi
  printf '%s|%s\n' "$_aa_uids" "$BLOCK_ALL" > "$XNB_ASIG"
  xnb_log "整个断网已部署：$BLOCK_ALL uid=$_aa_uids"
  return 0
}

# 规则齐全：每个 UID 的跳转都在，链里的规则条数等于域名个数。
xnb_rules_ok() {
  for _ro_u in $1; do
    xnb_ipt 4 -t filter -C OUTPUT -p tcp -m owner --uid-owner "$_ro_u" -j "$XNB_CHAIN" || return 1
  done
  _ro_n=0
  for _ro_h in $HOSTS; do _ro_n=$((_ro_n + 1)); done
  _ro_have=$(xnb_ipt 4 -t filter -S "$XNB_CHAIN" | grep -c "^-A $XNB_CHAIN ")
  [ "$_ro_have" = "$_ro_n" ]
}

# 整个断网的规则齐全：每个 UID 的跳转都在，链里正好两条。
xnb_all_ok() {
  for _ao_u in $1; do
    xnb_ipt 4 -t filter -C OUTPUT -m owner --uid-owner "$_ao_u" -j "$XNB_ACHAIN" || return 1
  done
  _ao_have=$(xnb_ipt 4 -t filter -S "$XNB_ACHAIN" | grep -c "^-A $XNB_ACHAIN ")
  [ "$_ao_have" = 2 ]
}

xnb_have_rules() { xnb_ipt 4 -t filter -S "$XNB_CHAIN" >/dev/null 2>&1; }
xnb_have_all() { xnb_ipt 4 -t filter -S "$XNB_ACHAIN" >/dev/null 2>&1; }

# 规则里实际生效的 UID：OUTPUT 里跳到这条链（默认 xnb_out）的那些（IPv4）。在哪个命名空间里看都一样。
xnb_live_uids() {
  xnb_ipt 4 -t filter -S OUTPUT 2>/dev/null | $XNB_AWK -v ch="${1:-$XNB_CHAIN}" '
    $1 == "-A" && $2 == "OUTPUT" && $NF == ch && $(NF - 1) == "-j" {
      for (i = 3; i < NF; i++) if ($i == "--uid-owner" && $(i + 1) ~ /^[0-9]+$/) print $(i + 1)
    }' | sort -n -u | tr '\n' ' ' | sed 's/ $//'
}

# 定向屏蔽这一半的核对。算不出目标 UID 时绝不删规则：沿用上次部署的 UID（规则被 netd 清掉
# 也照样补回）；连上次的也没有，就什么都不动。
xnb_check_host() {
  _ck_last=$(xnb_sig_uids)
  if xnb_uids; then
    _ck_uids=$XNB_UIDS
    if [ "$XNB_UIDS_SURE" = 0 ] && [ -n "$_ck_last" ]; then
      # 只按用户 0 算出来的不完整：并上上次部署的，规则不会因此变少。
      _ck_uids=$(printf '%s\n' $_ck_uids $_ck_last | sort -n -u | tr '\n' ' ')
      _ck_uids=${_ck_uids% }
      xnb_note "读不到用户列表（$XNB_USERS_DIR），并入上次部署的 uid：$_ck_uids"
    else
      xnb_note
    fi
  elif [ -n "$_ck_last" ]; then
    _ck_uids=$_ck_last
    xnb_note "算不出目标 uid（$XNB_UIDS_WHY），沿用上次部署的：$_ck_uids"
  else
    _ck_sp=$(xnb_sig_pkgs)
    if [ -n "$_ck_sp" ] && [ "$_ck_sp" != "$PACKAGES" ]; then
      # 配置里的目标应用改过、新的又算不出：旧规则已经不符合配置，删掉（不是“读不到”那种偶发失败）。
      xnb_note "目标应用改成了 $PACKAGES，但$XNB_UIDS_WHY；原来（$_ck_sp）的规则已删除"
      xnb_remove_host
      return 1
    fi
    xnb_note "算不出目标 uid（$XNB_UIDS_WHY），也没有上次部署的记录：现有规则不动"
    return 1
  fi
  _ck_sig="$_ck_uids|$HOSTS|$PACKAGES"
  if [ "${XNB_FORCE:-0}" = 1 ] || [ "$_ck_sig" != "$(cat "$XNB_SIG" 2>/dev/null)" ] \
     || ! xnb_rules_ok "$_ck_uids"; then
    xnb_apply "$_ck_uids"
    return $?
  fi
  xnb_counts
  printf '%s\n' "$XNB_SUM" > "$XNB_LIVE"
  return 0
}

# 整个断网这一半的核对，规则同上。BLOCK_ALL 为空表示不做：有残留的规则就删掉。
xnb_check_all() {
  if [ -z "$BLOCK_ALL" ]; then
    xnb_note_all
    if xnb_have_all; then xnb_remove_all "BLOCK_ALL 为空"; else rm -f "$XNB_ASIG"; fi
    return 0
  fi
  _cl_last=$(xnb_sig_auids)
  if xnb_resolve "$BLOCK_ALL"; then
    _cl_uids=$XR_UIDS
    if [ "$XR_SURE" = 0 ] && [ -n "$_cl_last" ]; then
      _cl_uids=$(printf '%s\n' $_cl_uids $_cl_last | sort -n -u | tr '\n' ' ')
      _cl_uids=${_cl_uids% }
      xnb_note_all "读不到用户列表（$XNB_USERS_DIR），整个断网并入上次部署的 uid：$_cl_uids"
    elif [ -n "$XR_SKIP" ]; then
      xnb_note_all "BLOCK_ALL 里这些是系统共享 UID，不能整个断网，已跳过：$XR_SKIP"
    else
      xnb_note_all
    fi
  elif [ -n "$_cl_last" ]; then
    _cl_uids=$_cl_last
    xnb_note_all "算不出整个断网的 uid（$XR_WHY），沿用上次部署的：$_cl_uids"
  else
    _cl_sp=$(xnb_asig_pkgs)
    if [ -n "$_cl_sp" ] && [ "$_cl_sp" != "$BLOCK_ALL" ]; then
      xnb_note_all "BLOCK_ALL 改成了 $BLOCK_ALL，但$XR_WHY；原来（$_cl_sp）的断网规则已删除"
      xnb_remove_all
      return 1
    fi
    xnb_note_all "算不出整个断网的 uid（$XR_WHY），也没有上次部署的记录：现有规则不动"
    return 1
  fi
  _cl_sig="$_cl_uids|$BLOCK_ALL"
  if [ "${XNB_FORCE:-0}" = 1 ] || [ "$_cl_sig" != "$(cat "$XNB_ASIG" 2>/dev/null)" ] \
     || ! xnb_all_ok "$_cl_uids"; then
    xnb_apply_all "$_cl_uids"
    return $?
  fi
  return 0
}

# 核对一次：该有的有、该删的删；什么都没变就只记下计数。只有“停用”会把规则全删掉。
xnb_check() {
  xnb_load
  if [ -e "$XNB_OFF" ]; then
    if xnb_have_rules || xnb_have_all; then xnb_remove "已停用"; fi
    return 0
  fi
  _cc_rc=0
  xnb_check_host || _cc_rc=1
  xnb_check_all || _cc_rc=1
  return $_cc_rc
}

# 从 Termux 或 root 管理器里拉起的进程属于那个应用的 cgroup（uid_<应用 UID>/pid_*）：应用进后台
# 会被冻结、被杀时整组一起杀。核对循环发现自己在应用的组里，就挪到根 cgroup。开机由 service.sh
# 拉起时在 uid_0 这类系统组里，不动。
xnb_leave_app_cgroup() {
  _lc_u=$($XNB_AWK -F'/uid_' 'NF > 1 { split($2, a, "/"); print a[1]; exit }' \
          "${XNB_SELFCG:-/proc/$$/cgroup}" 2>/dev/null)
  case "$_lc_u" in ''|0?*|*[!0-9]*) return 0;; esac
  [ $((_lc_u % 100000)) -ge 10000 ] || return 0
  if [ -w "$XNB_CGROOT/cgroup.procs" ] && printf '%s\n' "$$" > "$XNB_CGROOT/cgroup.procs" 2>/dev/null; then
    xnb_log "核对循环已移出应用的 cgroup（启动它的应用被冻结或被杀不会连累它）"
  else
    xnb_log "核对循环移出应用 cgroup 失败：启动它的应用被杀时它可能一起退出（重启后由 service.sh 拉起）"
  fi
}

# ---- 后台核对循环（单实例，身份比 /proc/PID/stat 的 starttime，不用会被 pid 复用骗过的 kill -0）
xnb_starttime() {
  _sx_l=""
  IFS= read -r _sx_l 2>/dev/null < "/proc/$1/stat" || [ -n "$_sx_l" ] || return 1
  _sx_l=${_sx_l##*) }
  # shellcheck disable=SC2086
  set -- $_sx_l
  [ $# -ge 20 ] || return 1
  case "$1" in Z|X|x) return 1;; esac
  printf '%s' "${20}"
}

xnb_loop_alive() {
  _la_p="" _la_s=""
  read -r _la_p _la_s 2>/dev/null < "$XNB_PIDF" || return 1
  case "$_la_p" in ''|*[!0-9]*) return 1;; esac
  [ "$(xnb_starttime "$_la_p")" = "$_la_s" ]
}

xnb_loop() {
  if ! mkdir "$XNB_LOCK" 2>/dev/null; then
    xnb_loop_alive && exit 0
    rmdir "$XNB_LOCK" 2>/dev/null
    mkdir "$XNB_LOCK" 2>/dev/null || exit 0
  fi
  printf '%s %s\n' "$$" "$(xnb_starttime $$)" > "$XNB_PIDF"
  # 退出时连同正在睡的 sleep 一起结束：busybox ash 里 sleep 是内建 applet，后台那个子进程
  # 的命令行和循环本身一模一样，留下来会被误认成还有一个核对循环。
  _lp_sl=""
  trap 'kill "$_lp_sl" 2>/dev/null; exit 0' INT TERM HUP
  trap 'rm -f "$XNB_PIDF"; rmdir "$XNB_LOCK" 2>/dev/null' EXIT
  xnb_log "核对循环启动 pid=$$：先每 ${XNB_FAST_INTERVAL}s 核对 ${XNB_FAST_ROUNDS} 次，之后每 ${XNB_INTERVAL}s"
  xnb_leave_app_cgroup
  _lp_fast=$XNB_FAST_ROUNDS
  while :; do
    xnb_rotate
    xnb_check
    if [ "$_lp_fast" -gt 0 ]; then
      _lp_fast=$((_lp_fast - 1))
      sleep "$XNB_FAST_INTERVAL" & _lp_sl=$!
    else
      sleep "$XNB_INTERVAL" & _lp_sl=$!
    fi
    wait "$_lp_sl"
  done
}

xnb_status() {
  xnb_load
  _st_live=$(xnb_live_uids)
  if [ -e "$XNB_OFF" ]; then _st_st="已停用（sh xnb.sh on 或点模块“操作”恢复）"
  elif xnb_have_rules && [ -n "$_st_live" ]; then _st_st="已启用，规则在位"
  elif xnb_have_rules; then _st_st="已启用，但 OUTPUT 里的跳转不在（核对循环会补回，或执行 sh xnb.sh apply）"
  else _st_st="已启用，但规则不在（开机核对还没跑，或部署失败，看 $XNB_LOG）"; fi
  echo "XMSF 定向屏蔽：$_st_st"
  echo "目标：$PACKAGES   规则里在拦的 uid：${_st_live:-无}"
  if xnb_uids; then
    if [ "$XNB_UIDS_SURE" = 0 ]; then
      echo "  （读不到用户列表 $XNB_USERS_DIR，只算得出 $XNB_UIDS；核对时会并入上次部署的，不会变少）"
    elif [ -n "$_st_live" ] && [ "$XNB_UIDS" != "$_st_live" ]; then
      echo "  （按当前用户算出的是 $XNB_UIDS，下次核对会更新规则）"
    fi
  else
    echo "  （这次算不出目标 uid：$XNB_UIDS_WHY。已有规则不受影响）"
  fi
  echo "屏蔽域名：$HOSTS"
  xnb_counts
  _st_c=$XNB_SUM
  _st_t=$(xnb_read_int "$XNB_TOTAL")
  echo "已拦截：本次部署以来 $_st_c 次，累计 $((_st_t + _st_c)) 次（每次 = 一次连接尝试被重置，没有数据发出去）"
  [ -n "$XNB_DETAIL" ] && printf '%s' "$XNB_DETAIL"
  # ---- 整个断网
  _st_al=$(xnb_live_uids "$XNB_ACHAIN")
  if [ -z "$BLOCK_ALL" ]; then
    if [ -n "$_st_al" ]; then echo "整个断网：配置里已清空，规则还在（uid $_st_al），下次核对会删掉"
    else echo "整个断网：未配置（config.conf 里的 BLOCK_ALL）"; fi
  else
    echo "整个断网：$BLOCK_ALL   规则里在断网的 uid：${_st_al:-无}"
    if xnb_resolve "$BLOCK_ALL"; then
      [ -n "$XR_SKIP" ] && echo "  （这些是系统共享 UID，不能整个断网，已跳过：$XR_SKIP）"
      [ -n "$_st_al" ] && [ "$XR_UIDS" != "$_st_al" ] && [ ! -e "$XNB_OFF" ] && \
        echo "  （按当前用户算出的是 $XR_UIDS，下次核对会更新规则）"
    else
      echo "  （这次算不出 uid：$XR_WHY。已有规则不受影响）"
    fi
    xnb_counts_all
    echo "  被拒：IPv4 $XNB_A4 个包，IPv6 $XNB_A6 个包（本次部署以来；一次 TCP 连接尝试 = 1 个包）"
  fi
  if xnb_loop_alive; then echo "核对循环：运行中（开机后前 10 分钟每 10 秒、之后每 10 分钟核对一次规则）"
  else echo "核对循环：未运行（重启后由 service.sh 拉起）"; fi
  _st_last=$(tail -n 1 "$XNB_LOG" 2>/dev/null)
  [ -n "$_st_last" ] && echo "最近日志：$_st_last"
  return 0
}

xnb_main() {
  xnb_pick_tools
  [ -n "$XNB_AWK" ] || { echo "error: 找不到 awk"; return 1; }
  case "${1:-status}" in
    status) xnb_status;;
    on)     rm -f "$XNB_OFF"; xnb_check
            if ! xnb_loop_alive; then
              ( sh "$XNB_MODDIR/xnb.sh" loop < /dev/null > /dev/null 2>&1 & )
              _mn_w=0
              while [ "$_mn_w" -lt 10 ] && ! xnb_loop_alive; do sleep 0.2 2>/dev/null || sleep 1; _mn_w=$((_mn_w + 1)); done
            fi
            xnb_status;;
    off)    : > "$XNB_OFF"; xnb_load; xnb_remove "手动停用"; xnb_status;;
    apply)  XNB_FORCE=1; xnb_check; xnb_status;;
    loop)   xnb_loop;;
    *)      echo "用法: sh xnb.sh {status|on|off|apply|loop}"; return 1;;
  esac
}

[ "${XNB_LIB:-0}" = 1 ] || xnb_main "$@"
