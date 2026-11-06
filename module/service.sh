#!/system/bin/sh
# 开机即拉起核对循环（不等开机完成）：xmsf 开机后很快就会往 hyperos.developer 上传，
# 实测在开机完成前后，规则必须赶在它前面。iptables 在这个阶段已可用；之后前 10 分钟
# 每 10 秒核对一次（netd 初始化若清掉规则会马上补回），再往后每 10 分钟一次。
MODDIR=${0%/*}
( sh "$MODDIR/xnb.sh" loop < /dev/null > /dev/null 2>&1 & )
