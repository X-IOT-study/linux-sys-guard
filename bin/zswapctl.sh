#!/usr/bin/env bash
# zswapctl.sh — 启用 / 关闭 / 体检 zswap（压缩 swap 缓存），可开机自启。
#   用法： sudo ./zswapctl.sh [on|off|verify]     默认 on
#
# 作用：换出的页先在内存里用 zstd 压缩存放，只有压缩池满了才写盘。
# 对慢速 swap 设备（eMMC、SD 卡、DRAM-less SSD、机械盘）收益最大：
# 省下大量随机写，也减少「切应用发涩」。
#
# 前提：内核有 CONFIG_ZSWAP=y（主流发行版内核默认都有）。
#   grep -q zswap /sys/module/zswap/parameters/enabled 2>/dev/null && echo supported
#   crypto/zstd 模块缺失时会尝试 modprobe zstd；仍然没有就退化为内核默认压缩器。
#
# 注意：只对**之后新换出**的页生效，已躺在 swap 里的页不会迁移过来。
#   想立刻全部走 zswap 需要 swapoff -a 再 swapon -a，而 swapoff 要把整个 swap
#   读回内存；空闲内存不够时会 OOM，脚本不会替你这么做。
#
# 可调环境变量：
#   POOL_PERCENT=10    zswap 压缩池上限（占 MemTotal 的百分比），默认 10
set -euo pipefail

P=/sys/module/zswap/parameters
UNIT=/etc/systemd/system/zswap.service
POOL_PERCENT="${POOL_PERCENT:-10}"

need_root() {
  [ "$(id -u)" -eq 0 ] || { echo "需要 root：sudo bash $0 $1" >&2; exit 1; }
}

show_state() {
  echo "--- 当前状态 ---"
  for f in enabled compressor zpool max_pool_percent; do
    printf '  %-16s %s\n' "$f" "$(cat "$P/$f" 2>/dev/null || echo '<不可读>')"
  done
  grep -E '^(Zswap|Zswapped|SwapTotal|SwapFree):' /proc/meminfo | sed 's/^/  /'
}

case "${1:-on}" in

on)
  need_root on
  modprobe zstd 2>/dev/null || true

  # 顺序不能反：compressor / zpool / max_pool_percent 必须在 enabled=1 之前写，
  # 否则返回 EBUSY。已启用时这几项就是只读的，所以先判断。
  if [ "$(cat "$P/enabled")" != "Y" ]; then
    echo zstd     > "$P/compressor"
    echo zsmalloc > "$P/zpool"
    echo "$POOL_PERCENT" > "$P/max_pool_percent"
    echo 1        > "$P/enabled"
    echo "zswap 已启用（本次开机）"
  else
    echo "zswap 本次开机已处于启用状态，跳过写入"
  fi

  # 开机自启：oneshot unit，在 swap 激活前把 sysfs 配好。
  # 不要 After=sysinit.target：那会和 WantedBy=swap.target 形成依赖环，
  # systemd 会删掉 job，启动日志里出现 "ordering cycle" 警告。
  cat > "$UNIT" <<UNIT_EOF
[Unit]
Description=Enable zswap (zstd + zsmalloc)
DefaultDependencies=no
After=systemd-modules-load.service
Before=swap.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStartPre=-/sbin/modprobe zstd
ExecStart=/bin/sh -c 'echo zstd > /sys/module/zswap/parameters/compressor; echo zsmalloc > /sys/module/zswap/parameters/zpool; echo ${POOL_PERCENT} > /sys/module/zswap/parameters/max_pool_percent; echo 1 > /sys/module/zswap/parameters/enabled'
ExecStop=/bin/sh -c 'echo 0 > /sys/module/zswap/parameters/enabled'

[Install]
WantedBy=swap.target
UNIT_EOF

  systemctl daemon-reload
  systemctl enable zswap.service >/dev/null 2>&1 || true
  echo "已设为开机自启：$UNIT"
  echo
  show_state
  echo
  total_kb=$(awk '/^MemTotal:/{print $2}' /proc/meminfo)
  avail_kb=$(awk '/^MemAvailable:/{print $2}' /proc/meminfo)
  pool_mb=$(( total_kb / 1024 * POOL_PERCENT / 100 ))
  printf '池上限 %s%% × %.1f GB ≈ %d MB（当前 MemAvailable %.1f GB）。\n' \
    "$POOL_PERCENT" "$(awk -v v="$total_kb" 'BEGIN{print v/1048576}')" \
    "$pool_mb" "$(awk -v v="${avail_kb:-0}" 'BEGIN{print v/1048576}')"
  echo "压缩池本身占 RAM：池给太大反而会把可用内存吃光。"
  echo "跑一两天后若命中率高、且 MemAvailable 仍然充裕，可以调大（要先 enabled=0 再改，否则 EBUSY）："
  echo "  sudo sh -c 'echo 0 > $P/enabled; echo 15 > $P/max_pool_percent; echo 1 > $P/enabled'"
  echo
  echo "看命中率（需 root）：sudo bash $0 verify"
  ;;

off)
  need_root off
  systemctl disable --now zswap.service >/dev/null 2>&1 || true
  rm -f "$UNIT"
  systemctl daemon-reload
  echo 0 > "$P/enabled"
  echo "zswap 已关闭，开机不再启用"
  show_state
  ;;

verify)
  # 不需要 root：判断效果只要 /proc/meminfo 里的两个数。
  #   Zswap    = 压缩池当前占用（kB）
  #   Zswapped = 累计有多少内存从 zswap 走过（kB）
  #   比值 Zswapped/Zswap 就是压缩率；池满后被挤回磁盘的页数只有 debugfs 能看。
  z_pool=$(awk '/^Zswap:/{print $2}' /proc/meminfo)
  z_swapped=$(awk '/^Zswapped:/{print $2}' /proc/meminfo)
  z_pool=${z_pool:-0}; z_swapped=${z_swapped:-0}

  if [ "$z_pool" -gt 0 ] 2>/dev/null; then
    ratio=$(awk -v a="$z_swapped" -v b="$z_pool" 'BEGIN{printf "%.2f", a/b}')
    printf '压缩池占用      %8.1f MB\n' "$(awk -v v="$z_pool" 'BEGIN{print v/1024}')"
    printf '累计经过 zswap  %8.1f MB\n' "$(awk -v v="$z_swapped" 'BEGIN{print v/1024}')"
    printf '压缩率          %8s : 1\n' "$ratio"
    printf '池上限          %8.0f MB（MemTotal 的 %s%%）\n' \
      "$(awk -v t="$(awk '/^MemTotal:/{print $2}' /proc/meminfo)" -v p="$(cat "$P/max_pool_percent")" 'BEGIN{print t/1024*p/100}')" \
      "$(cat "$P/max_pool_percent")"
  else
    echo "压缩池还是空的（Zswap=0）。这正常：zswap 只接管**之后新换出**的页，"
    echo "要等内存压力再产生新的换出才会有数字。过一阵再看。"
  fi

  S=/sys/kernel/debug/zswap/stats
  if [ -e "$S" ] && [ -r "$S" ] 2>/dev/null; then
    echo
    echo "--- debugfs 明细 ---"
    sed 's/^/  /' "$S"
    echo "  （written_back_pages 是池满后被挤回磁盘的页数，越小越好；"
    echo "    pool_limit_hit 持续增长说明 ${POOL_PERCENT}% 不够，可以调大）"
  elif [ "$(id -u)" -eq 0 ]; then
    echo
    echo "（没有 $S —— 这版内核/配置没导出该文件；上面的 /proc/meminfo 数字已足够判断。）"
  fi
  echo
  show_state
  ;;

*)
  echo "用法：sudo bash $0 [on|off|verify]" >&2
  exit 1
  ;;
esac