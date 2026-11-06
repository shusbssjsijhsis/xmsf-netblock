#!/system/bin/sh
# root 管理器里点“操作”：在启用 / 停用之间切换，并显示拦截次数。
MODDIR=${0%/*}
[ "$MODDIR" = "$0" ] && MODDIR=.
DATA=${XNB_DATA:-/data/adb/xmsf_netblock}
echo "════════════════════════════════════"
echo " XMSF 定向屏蔽 + 应用断网"
echo "════════════════════════════════════"
if [ -e "$DATA/disabled" ]; then
  echo "  本次操作：启用（再点一次停用）"
  echo ""
  sh "$MODDIR/xnb.sh" on
else
  echo "  本次操作：停用（再点一次重新启用）"
  echo ""
  sh "$MODDIR/xnb.sh" off
fi
