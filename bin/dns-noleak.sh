#!/usr/bin/env bash
# ============================================================
# dns-noleak.sh — 让 systemd-resolved 只用加密的全局 DNS，
#                 不再把查询发往本地路由器 / 运营商。
#
# 问题：resolved 会把 DHCP 拿到的「per-link DNS」与全局 DNS 并行使用，
#       而 per-link 查询会把源地址绑定到网卡地址，从而绕开 TUN / 策略路由。
#       结果就是 DNS 明文直连路由器，泄漏给运营商。
#
# 做法：
#   1. 写全局 DNS-over-TLS 配置（/etc/systemd/resolved.conf.d/），与网络无关。
#   2. 让「per-link DNS 永远不出现」——按网络后端分三种：
#        NetworkManager  → 连接级 ignore-auto-dns + dispatcher 钩子
#        systemd-networkd→ .network 的 UseDNS=no 落盘 + networkd-dispatcher 钩子
#        其它/未知      → systemd timer 每 30s 兜底清理（能力有限，会提示）
#
# 用法：
#   sudo ./dns-noleak.sh              # 安装（幂等，可反复跑）
#   ./dns-noleak.sh --check           # 只体检，不需要 root
#   sudo ./dns-noleak.sh --revert     # 全部还原
#   sudo ./dns-noleak.sh --dry-run    # 只打印将要做的改动
#
# 可调环境变量：
#   DNS_SERVERS="1.1.1.1#cloudflare-dns.com 9.9.9.9#dns.quad9.net"
#       完全覆盖解析器列表
#   EXTRA_DNS="1.0.0.1#cloudflare-dns.com"
#       追加到默认列表后面
#   NO_PROBE=1        跳过连通性预检（离线环境用）
#   FORCE=1           即使所有解析器都探测不通也照样写入
#
# 依赖：Linux + systemd(239+) + systemd-resolved + resolvectl
# ============================================================
set -uo pipefail

readonly PROG="${0##*/}"
readonly VERSION="1.0.0"

readonly DOT_CONF=/etc/systemd/resolved.conf.d/50-dns-privacy.conf
readonly NM_HOOK=/etc/NetworkManager/dispatcher.d/90-dns-noleak
readonly NETD_HOOK=/etc/networkd-dispatcher/routable.d/90-dns-noleak
readonly NETD_DROPIN_DIR=/etc/systemd/network
readonly TIMER_UNIT=/etc/systemd/system/dns-noleak-guard.timer
readonly TIMER_SERVICE=/etc/systemd/system/dns-noleak-guard.service

readonly DEFAULT_SERVERS="1.1.1.1#cloudflare-dns.com 9.9.9.9#dns.quad9.net 223.5.5.5#dns.alidns.com"

TS="$(date +%Y%m%d-%H%M%S)"
BK="/var/backups/dns-noleak-$TS"

DRY=0
FORCE="${FORCE:-0}"
NO_PROBE="${NO_PROBE:-0}"

# ---------------------------------------------------------------- 基础
die()  { printf '%s: %s\n' "$PROG" "$*" >&2; exit 1; }
say()  { printf '%s\n' "$*"; }
warn() { printf '!! %s\n' "$*" >&2; }
have() { command -v "$1" >/dev/null 2>&1; }

need_root() {
  [ "$(id -u)" -eq 0 ] || die "需要 root：sudo ./$PROG ${1:-}"
}

# 干跑时只打印，不执行
run() {
  if [ "$DRY" -eq 1 ]; then
    printf '  [dry-run] %s\n' "$*"
  else
    "$@"
  fi
}

write_file() { # write_file <path> <mode>  （内容从 stdin 读）
  local path="$1" mode="$2"
  if [ "$DRY" -eq 1 ]; then
    printf '  [dry-run] 写入 %s (mode %s, %s 字节)\n' "$path" "$mode" "$(wc -c)"
    cat >/dev/null
    return 0
  fi
  mkdir -p "$(dirname "$path")" || return 1
  cat >"$path" || return 1
  chown root:root "$path" 2>/dev/null || true
  chmod "$mode" "$path" || return 1
}

# ---------------------------------------------------------------- 后端探测
# 返回 nm | networkd | none
detect_backend() {
  if systemctl is-active --quiet NetworkManager 2>/dev/null && have nmcli; then
    echo nm
  elif systemctl is-active --quiet systemd-networkd 2>/dev/null; then
    echo networkd
  else
    echo none
  fi
}

# 当前有地址的物理网卡（wifi/ethernet），排除 lo/tun/bridge/docker/veth
active_devs() {
  local backend; backend="$(detect_backend)"
  if [ "$backend" = nm ]; then
    nmcli -t -f DEVICE,TYPE,STATE device 2>/dev/null |
      awk -F: '$2 ~ /^(wifi|ethernet)$/ && $3 ~ /^connected/ {print $1}'
  else
    # 退化为「有全局地址、且不是虚拟设备」的接口
    ip -brief address show 2>/dev/null |
      awk '$1 ~ /^(lo|docker.*|veth.*|virbr.*|br-.*|vnet.*|tun.*|tap.*|wlx[0-9a-f]+)$/ {next}
           $0 ~ /(inet|inet6) / {print $1}'
  fi
}

# 某网卡上的 DNS 服务器列表（去前缀、去空白）
link_dns() {
  resolvectl dns "$1" 2>/dev/null | sed 's/^[^:]*://' | tr -d '[:space:]'
}

# 列出仍有 per-link DNS 的物理网卡："wlo1(192.168.0.1)"
leftover_dns() {
  local d s out=""
  for d in $(active_devs); do
    s="$(link_dns "$d")"
    [ -n "$s" ] && out="$out $d($s)"
  done
  printf '%s' "${out# }"
}

# 清理所有物理网卡上的 per-link DNS
clear_all_links() {
  local d rc=0
  for d in $(active_devs); do
    [ -n "$(link_dns "$d")" ] || continue
    run resolvectl dns "$d" "" >/dev/null 2>&1 || rc=1
  done
  run resolvectl flush-caches >/dev/null 2>&1 || true
  return $rc
}

# ---------------------------------------------------------------- DoT 预检
# dot_probe <ip> <sni> —— 能完成 TLS 握手才算通过
dot_probe() {
  local ip="$1" sni="$2" out dighelp
  # 不能写 `dig -h | grep -q ...`：grep -q 命中即退出会把 dig 弄成 SIGPIPE(141)，
  # 配合 set -o pipefail 会误判成「dig 不支持 +tls」。先落变量再查。
  dighelp="$(dig -h 2>&1 || true)"
  if have dig && printf '%s' "$dighelp" | grep -q -- '+tls'; then
    dig +tls="$sni" +time=3 +tries=1 +short @"$ip" example.com A >/dev/null 2>&1 && return 0
  fi
  if have openssl; then
    out="$(timeout 5 openssl s_client -connect "$ip:853" -servername "$sni" -brief \
           </dev/null 2>&1)" || true
    printf '%s' "$out" | grep -qi 'protocol version' && return 0
  fi
  # 最后退化为端口可达性（可能被中间设备放行 TCP 但仍打断 TLS，只作参考）
  timeout 3 bash -c "exec 3<>/dev/tcp/$ip/853" 2>/dev/null
}

# 逐个探测，返回以空格分隔的可用服务器列表
filter_reachable() {
  local list="$1" out="" spec ip sni
  for spec in $list; do
    ip="${spec%%#*}"
    sni="${spec#*#}"
    [ "$sni" = "$spec" ] && sni=""
    if dot_probe "$ip" "$sni"; then
      out="$out $spec"
    else
      warn "解析器 $spec 的 DoT 探测失败，已跳过"
    fi
  done
  printf '%s' "${out# }"
}

# ---------------------------------------------------------------- 全局 DoT
install_dot_conf() {
  local servers="$1"
  say ">> 写入全局 DoT 配置"
  write_file "$DOT_CONF" 0644 <<EOF
[Resolve]
DNS=$servers
DNSOverTLS=yes
Domains=~.
FallbackDNS=
DNSSEC=no
EOF
}

# ---------------------------------------------------------------- NM 后端
install_nm_backend() {
  say ">> 后端：NetworkManager"

  # 每个连接永久关闭 DHCP DNS
  local n=0 u
  for u in $(nmcli -t -f UUID,TYPE con show 2>/dev/null |
             awk -F: '$2 ~ /^(802-11-wireless|802-3-ethernet)$/ {print $1}'); do
    if [ "$DRY" -eq 1 ]; then
      printf '  [dry-run] nmcli con mod %s ipv4.ignore-auto-dns yes ipv6.ignore-auto-dns yes\n' "$u"
      n=$((n + 1))
    elif nmcli con mod "$u" ipv4.ignore-auto-dns yes ipv6.ignore-auto-dns yes >/dev/null 2>&1; then
      n=$((n + 1))
    else
      warn "无法修改连接 $u（已跳过）"
    fi
  done
  say "   已有 $n 个连接关闭 DHCP DNS"

  # 事件钩子：新网络、租约变化时清掉并落盘
  say ">> 安装 NetworkManager 钩子"
  write_file "$NM_HOOK" 0755 <<'SH'
#!/bin/sh
# 由 dns-noleak.sh 安装。
# 网络就绪 / 租约变化后：清掉 DHCP 下发的 per-link DNS，
# 让 systemd-resolved 只用全局 DoT 服务器，并把设置永久写回该连接。
IFACE="$1"
ACTION="$2"

case "$ACTION" in
  up|dhcp4-change|dhcp6-change) ;;
  *) exit 0 ;;
esac

# resolvectl 处理不了非 ASCII / 含空格的接口名，跳过
case "$IFACE" in
  ""|*[!A-Za-z0-9_.-]*) exit 0 ;;
esac

servers=$(/usr/bin/resolvectl dns "$IFACE" 2>/dev/null | sed 's/^[^:]*://' | tr -d '[:space:]')
[ -n "$servers" ] || exit 0

# 等 NM 通过 D-Bus 把 DNS 推完，避开时序竞争
sleep 0.3

/usr/bin/resolvectl dns "$IFACE" "" >/dev/null 2>&1
/usr/bin/resolvectl flush-caches >/dev/null 2>&1

# 永久修好这个连接：下次连同一网络，NM 不再下发 DHCP DNS
if [ -n "${CONNECTION_UUID:-}" ]; then
  /usr/bin/nmcli con mod "$CONNECTION_UUID" \
      ipv4.ignore-auto-dns yes ipv6.ignore-auto-dns yes >/dev/null 2>&1
fi
exit 0
SH
}

# ---------------------------------------------------------------- networkd 后端
install_networkd_backend() {
  say ">> 后端：systemd-networkd"

  # 已存在的 .network 都加 drop-in（UseDNS=no 只在 [Network] 段生效）
  local f name n=0
  for f in /etc/systemd/network/*.network /usr/lib/systemd/network/*.network \
           /run/systemd/network/*.network; do
    [ -f "$f" ] || continue
    name="$(basename "$f")"
    write_file "$NETD_DROPIN_DIR/$name.d/90-no-dhcp-dns.conf" 0644 <<'EOF'
# 由 dns-noleak.sh 安装：不要让 DHCP 下发 DNS 服务器
[Network]
UseDNS=no
EOF
    n=$((n + 1))
  done
  if [ "$n" -eq 0 ]; then
    warn "没有找到任何 .network 文件；若之后新建，请自行加 [Network] UseDNS=no"
  else
    say "   已为 $n 个 .network 文件加 drop-in"
  fi

  # networkd-dispatcher 钩子（可选，装了才有事件驱动）
  if [ -d /etc/networkd-dispatcher/routable.d ]; then
    say ">> 安装 networkd-dispatcher 钩子"
    write_file "$NETD_HOOK" 0755 <<'SH'
#!/bin/sh
# 由 dns-noleak.sh 安装：接口进入 routable 状态后清掉 per-link DNS。
IFACE="$1"
case "$IFACE" in ""|*[!A-Za-z0-9_.-]*) exit 0 ;; esac
servers=$(/usr/bin/resolvectl dns "$IFACE" 2>/dev/null | sed 's/^[^:]*://' | tr -d '[:space:]')
[ -n "$servers" ] || exit 0
sleep 0.3
/usr/bin/resolvectl dns "$IFACE" "" >/dev/null 2>&1
/usr/bin/resolvectl flush-caches >/dev/null 2>&1
exit 0
SH
  else
    warn "未装 networkd-dispatcher：将使用定时兜底"
    install_timer_backend
    return
  fi

  run systemctl restart systemd-networkd >/dev/null 2>&1 || warn "systemd-networkd 重启失败"
}

# ---------------------------------------------------------------- 兜底定时器
install_timer_backend() {
  say ">> 后端：无（未知网络管理器）——安装 30s 定时兜底"
  write_file "$TIMER_SERVICE" 0644 <<'EOF'
[Unit]
Description=dns-noleak: clear per-link DNS servers
After=systemd-resolved.service

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'for d in $(resolvectl dns | sed -n "s/^Link [0-9]* (\([^)]*\)): *[^ ]/\1/p"); do case "$d" in *[!A-Za-z0-9_.-]*) continue;; esac; resolvectl dns "$d" "" >/dev/null 2>&1; done; resolvectl flush-caches >/dev/null 2>&1'
EOF
  write_file "$TIMER_UNIT" 0644 <<'EOF'
[Unit]
Description=dns-noleak guard timer

[Timer]
OnBootSec=20s
OnUnitActiveSec=30s
AccuracySec=5s

[Install]
WantedBy=timers.target
EOF
  run systemctl daemon-reload >/dev/null 2>&1 || true
  run systemctl enable --now dns-noleak-guard.timer >/dev/null 2>&1 || warn "定时器启用失败"
}

# ---------------------------------------------------------------- 回滚
revert() {
  say ">> 回滚中..."
  rm -f "$DOT_CONF" "$NM_HOOK" "$NETD_HOOK" "$TIMER_UNIT" "$TIMER_SERVICE"

  # networkd drop-in
  local d
  for d in "$NETD_DROPIN_DIR"/*.network.d/90-no-dhcp-dns.conf; do
    [ -e "$d" ] && rm -f "$d" && rmdir "$(dirname "$d")" 2>/dev/null
  done

  # NM 连接恢复原值
  if [ -f "$BK/connections.txt" ]; then
    local u v4 v6
    while read -r u v4 v6; do
      [ -n "${u:-}" ] || continue
      nmcli con mod "$u" ipv4.ignore-auto-dns "${v4:-no}" \
                             ipv6.ignore-auto-dns "${v6:-no}" >/dev/null 2>&1 || true
    done <"$BK/connections.txt"
  fi

  systemctl daemon-reload >/dev/null 2>&1 || true
  systemctl restart systemd-resolved >/dev/null 2>&1 || true
  systemctl restart NetworkManager >/dev/null 2>&1 || true
  sleep 1
  say ">> 已还原。备份保留在: $BK"
  exit 1
}

manual_revert() {
  BK="$(ls -dt /var/backups/dns-noleak-* 2>/dev/null | head -1)"
  say ">> 使用备份: ${BK:-<无>}"
  revert
}

# ---------------------------------------------------------------- 体检
check() {
  local backend; backend="$(detect_backend)"
  local left
  left="$(leftover_dns)"

  say "================ dns-noleak 体检 ================"
  say "网络后端: $backend"

  say ""
  say "--- 全局解析器 ---"
  resolvectl status 2>/dev/null | sed -n '1,5p'

  say ""
  say "--- per-link DNS（有地址 = 泄漏点）---"
  resolvectl dns 2>/dev/null

  say ""
  if [ -z "$left" ]; then
    say "OK  没有 per-link DNS"
  else
    say "!!  仍有 per-link DNS: $left"
  fi

  say ""
  say "--- 安装痕迹 ---"
  local f
  for f in "$DOT_CONF" "$NM_HOOK" "$NETD_HOOK" "$TIMER_UNIT"; do
    if [ -e "$f" ]; then say "  有  $f"; else say "  无  $f"; fi
  done

  say ""
  say "--- 实际解析 ---"
  resolvectl query example.com 2>&1 | sed -n '1,4p'

  say ""
  say "--- 出口解析器归属 ---"
  curl -sL --max-time 8 https://edns.ip-api.com/json 2>/dev/null | head -c 300
  say ""
  say "================================================="
}

# ---------------------------------------------------------------- 安装
install() {
  # dry-run 只打印，不需要 root
  [ "$DRY" -eq 1 ] || need_root install

  local backend; backend="$(detect_backend)"
  have resolvectl || die "缺少 resolvectl（需要 systemd-resolved）"
  have systemctl  || die "缺少 systemctl（需要 systemd）"

  # 1) 解析器列表
  local servers="${DNS_SERVERS:-$DEFAULT_SERVERS}"
  if [ -n "${EXTRA_DNS:-}" ] && [ -z "${DNS_SERVERS:-}" ]; then
    servers="$servers $EXTRA_DNS"
  fi

  say ">> 候选 DoT 解析器: $servers"
  if [ "$NO_PROBE" -eq 1 ]; then
    say ">> 已跳过连通性预检 (NO_PROBE=1)"
  else
    say ">> 探测 DoT 连通性..."
    local ok; ok="$(filter_reachable "$servers")"
    if [ -z "$ok" ]; then
      if [ "$FORCE" -eq 1 ]; then
        warn "全部不可达，但 FORCE=1，继续使用原列表"
      else
        die "所有 DoT 解析器都不可达。请检查网络，或用 DNS_SERVERS=... 指定可用的，或 FORCE=1 强制写入"
      fi
    else
      servers="$ok"
    fi
    say ">> 实际使用: $servers"
  fi

  # 2) 备份
  if [ "$DRY" -eq 0 ]; then
    mkdir -p "$BK"
    cp -a /etc/systemd/resolved.conf "$BK/" 2>/dev/null || true
    [ -f "$DOT_CONF" ]  && cp -a "$DOT_CONF"  "$BK/" 2>/dev/null || true
    [ -f "$NM_HOOK" ]   && cp -a "$NM_HOOK"   "$BK/" 2>/dev/null || true
    [ -f "$NETD_HOOK" ] && cp -a "$NETD_HOOK" "$BK/" 2>/dev/null || true
    resolvectl status >"$BK/status-before.txt" 2>&1 || true
    : >"$BK/connections.txt"
    local u
    for u in $(nmcli -t -f UUID,TYPE con show 2>/dev/null |
               awk -F: '$2 ~ /^(802-11-wireless|802-3-ethernet)$/ {print $1}'); do
      printf '%s %s %s\n' "$u" \
        "$(nmcli -g ipv4.ignore-auto-dns con show "$u" 2>/dev/null)" \
        "$(nmcli -g ipv6.ignore-auto-dns con show "$u" 2>/dev/null)" >>"$BK/connections.txt"
    done
    say ">> 备份: $BK"
  fi

  # 3) 应用
  install_dot_conf "$servers"

  case "$backend" in
    nm)       install_nm_backend ;;
    networkd) install_networkd_backend ;;
    *)        warn "未识别网络管理器，仅安装全局 DoT + 定时兜底"
              install_timer_backend ;;
  esac

  # 4) 使其立即生效
  run systemctl restart systemd-resolved >/dev/null 2>&1 || die "systemd-resolved 重启失败"
  if [ "$DRY" -eq 0 ]; then
    sleep 1
    if [ "$backend" = nm ]; then
      local d
      for d in $(active_devs); do
        nmcli device reapply "$d" >/dev/null 2>&1 || true
      done
      sleep 1
    fi
    clear_all_links || true
  fi

  [ "$DRY" -eq 1 ] && { say ">> dry-run 结束，未做任何改动"; exit 0; }

  # 5) 验证
  say ">> 验证解析..."
  if ! resolvectl query example.com >"$BK/verify.txt" 2>&1; then
    cat "$BK/verify.txt"; revert
  fi
  local left; left="$(leftover_dns)"
  [ -z "$left" ] || { warn "仍有 per-link DNS: $left"; revert; }

  say ""
  say "================ 安装完成 ================"
  resolvectl status 2>/dev/null | sed -n '1,6p'
  say ""
  say "--- per-link DNS（应为空）---"
  resolvectl dns 2>/dev/null
  say ""
  say "--- 解析示例 ---"
  sed -n '1,4p' "$BK/verify.txt"
  say "------------------------------------------"
  if resolvectl status 2>/dev/null >"$BK/status-after.txt"; then :; fi
  if grep -q '+DNSOverTLS' "$BK/status-after.txt" 2>/dev/null; then
    say "OK: DNSOverTLS 已启用"
  else
    warn "未检测到 +DNSOverTLS，请检查 $DOT_CONF"
  fi
  say "=========================================="
  say "体检: ./$PROG --check"
  say "还原: sudo ./$PROG --revert"
  say "备份: $BK"
}

# ---------------------------------------------------------------- 入口
usage() {
  sed -n '2,/^# ====/{/^# ====/d;s/^# \{0,1\}//;p}' "$0"
}

case "${1:-install}" in
  --check)  check ;;
  --revert) need_root --revert; manual_revert ;;
  --dry-run) DRY=1; install ;;
  -h|--help|help) usage ;;
  --version) echo "$PROG $VERSION" ;;
  install|"") install ;;
  *) die "未知参数: $1（--help 查看用法）" ;;
esac
