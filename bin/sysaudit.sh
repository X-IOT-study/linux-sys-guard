#!/usr/bin/env bash
# ============================================================
# 只读系统健康审计采集器
#
# 特性
#   - 只读：不调用 sudo，不写系统文件，不联网写盘；每个采集命令都有超时上限
#   - 原子输出：先写 .tmp 再 mv，中途崩溃不会留下半截报告
#   - 失败可见：命令非零退出会写 [exit=N]，不再被管道吞掉
#   - 分节可跑：--section 只跑需要的部分，方便复用
#
# 用法
#   ./audit.sh                          # 全部五节，输出到脚本所在目录
#   ./audit.sh --outdir ~/audit-out     # 指定输出目录
#   ./audit.sh --section storage,services
#   ./audit.sh --list                   # 列出所有分节
#   ./audit.sh --timeout 60 --strict    # 单命令超时 60s；有采集失败则退出码 3
#
# 退出码
#   0  全部请求的分节都写出了文件（里面可能仍有 [exit=N]，那是被采集对象的状态）
#   1  有分节没写出文件
#   2  参数错误 / 输出目录不可写 / 缺少必需命令
#   3  指定了 --strict，且有采集命令失败
#
# 环境变量
#   AUDIT_TIMEOUT  单命令超时秒数，默认 30（等价于 --timeout）
# ============================================================

# 不用 set -e：采集中单条命令失败是常态，应由 try() 记录后继续。
# 用 set -u：未定义变量直接报错，避免「空变量拼出错误命令」这类静默 bug。
set -u

OUT="$(cd "$(dirname "$0")" && pwd)"
DATE="$(date '+%Y-%m-%d %H:%M:%S %Z')"
# C locale：df/lsblk/free 的列名与小数点、排序都稳定；journalctl 也输出英文，grep 才匹配得上
export LC_ALL=C

TIMEOUT="${AUDIT_TIMEOUT:-30}"
ONLY=""        # 空 = 全部；否则是空格分隔的 section id 列表
STRICT=0
WRITE_FAILS=0
TOTAL_PROBE_FAILS=0

have() { command -v "$1" >/dev/null 2>&1; }

usage() {
  sed -n '2,/^# ====/{/^# ====/d;s/^# \{0,1\}//;p}' "$0"
}

die() { printf 'error: %s\n' "$*" >&2; exit 2; }

###### 分节选择 ################################################

add_one() { case " $ONLY " in *" $1 "*) ;; *) ONLY="${ONLY:+$ONLY }$1" ;; esac; }

add_section() { # 接受 "storage,services" 或 "all"
  local s n=0
  for s in $(printf '%s' "$1" | tr ',' ' '); do
    n=$((n + 1))
    case "$s" in
      system|system-info) add_one system ;;
      hardware)           add_one hardware ;;
      storage)            add_one storage ;;
      services)           add_one services ;;
      network)            add_one network ;;
      all) add_one system; add_one hardware; add_one storage
           add_one services; add_one network ;;
      *) die "未知 section：$s（用 --list 查看）" ;;
    esac
  done
  [ "$n" -eq 0 ] && die "--section 参数为空（用 --list 查看可用分节）"
}

want() { # want <id>：未指定 --section 时全部为真
  [ -z "$ONLY" ] && return 0
  case " $ONLY " in *" $1 "*) return 0 ;; esac
  return 1
}

list_sections() {
  cat <<'EOF'
system    system-info.txt  主机 / CPU / 内存 / PCI / GPU 驱动 / CUDA
hardware  hardware.txt     sensors / 温度 / 频率 / 功耗 / 电池 / 风扇
storage   storage.txt      块设备 / 挂载 / SMART / ext4 / 空间
services  services.txt     systemd 单元 / journal / 内核日志 / OOM
network   network.txt      网卡 / 路由 / DNS / 防火墙 / 开发环境
EOF
}

###### 输出与采集核心 ##########################################

hdr() { printf '\n===== %s =====\n' "$*"; }

logcmd() { # 渲染命令行：ASCII 原样，含空格/中文的加单引号（不用 %q——C locale 会把中文转成八进制）
  local a out=""
  for a in "$@"; do
    case "$a" in
      *"'"*)                    out="$out\"$a\" " ;;
      *[!A-Za-z0-9_./:=,@%+-]*) out="$out'$a' " ;;
      *)                        out="$out$a " ;;
    esac
  done
  printf '%s' "$out"
}

CAP_OUT=""
CAP_RC=0
to() { # to <cmd...>：外部命令的超时包装，供 shell 函数内部使用（timeout 缺失时直接跑）
  if have timeout; then timeout "$TIMEOUT" "$@"; else "$@"; fi
}

capture() { # capture <cmd...> -> CAP_OUT / CAP_RC；非 shell 函数一律套 timeout
  CAP_OUT=""
  CAP_RC=0
  [ $# -eq 0 ] && { CAP_OUT="(空命令，已跳过)"; CAP_RC=1; return 0; }
  if declare -F "$1" >/dev/null 2>&1; then
    # shell 函数无法交给 timeout 执行，函数内部自己保证不作长时间阻塞
    CAP_OUT="$("$@" 2>&1)"; CAP_RC=$?
  elif have timeout; then
    CAP_OUT="$(timeout "$TIMEOUT" "$@" 2>&1)"; CAP_RC=$?
  else
    CAP_OUT="$("$@" 2>&1)"; CAP_RC=$?
  fi
  if [ "$CAP_RC" -eq 124 ] || [ "$CAP_RC" -eq 137 ]; then
    CAP_OUT="${CAP_OUT}"$'\n'"[timeout: 超过 ${TIMEOUT}s 已终止，本节结果不完整]"
  fi
  return 0
}

try() { # try "<label>" <cmd...>  -- 记录退出码与输出，从不中断脚本
  local label="${1:-}"
  [ $# -gt 0 ] && shift
  hdr "${label:-(无标签)}"
  printf '$ %s\n' "$(logcmd "$@")"
  capture "$@"
  printf '%s\n' "$CAP_OUT"
  [ "$CAP_RC" -ne 0 ] && printf '[exit=%d]\n' "$CAP_RC"
  return 0
}

try_grep() { # try_grep "<label>" "<ERE>" <cmd...>
  local label="$1" pat="$2"; shift 2
  hdr "$label"
  printf '$ %s| grep -iE %q\n' "$(logcmd "$@")" "$pat"
  capture "$@"
  if [ "$CAP_RC" -ne 0 ]; then
    printf '%s\n' "$CAP_OUT" | tail -20
    printf '[exit=%d] 采集命令失败，本节输出不完整（不等于「没问题」）\n' "$CAP_RC"
    return 0
  fi
  local hits n total
  hits="$(printf '%s\n' "$CAP_OUT" | grep -iE -- "$pat")"
  n="$(printf '%s\n' "$hits" | grep -c . || true)"
  if [ "${n:-0}" -eq 0 ]; then
    total="$(printf '%s\n' "$CAP_OUT" | grep -c . || true)"
    printf '(无匹配：已扫过 %s 行日志，未出现 %s)\n' "${total:-0}" "$pat"
  else
    printf '%s\n' "$hits" | tail -n 120
    [ "$n" -gt 120 ] && printf '(共 %d 行匹配，上面只显示最后 120 行)\n' "$n"
  fi
  return 0
}

try_tail() { # try_tail "<label>" <行数> <cmd...>
  local label="$1" n="$2"; shift 2
  hdr "$label"
  printf '$ %s| tail -%s\n' "$(logcmd "$@")" "$n"
  capture "$@"
  printf '%s\n' "$CAP_OUT" | tail -n "$n"
  [ "$CAP_RC" -ne 0 ] && printf '[exit=%d] 采集命令失败，本节输出不完整\n' "$CAP_RC"
  return 0
}

###### 复合采集（shell 函数，内部自己做存在性判断）############

list_disks() { to lsblk -dno NAME,TYPE 2>/dev/null | awk '$2=="disk"{print "/dev/"$1}'; }

smart_all() {
  local devs d
  if ! have smartctl; then
    echo "(smartctl 未安装：$(pkg_hint smartmontools) 后可采集 SMART)"
    return 0
  fi
  devs="$(list_disks)"
  if [ -z "$devs" ]; then
    echo "(lsblk 没有列出任何 disk)"
    return 0
  fi
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    echo "--- $d"
    if [ ! -e "$d" ]; then
      echo "(skipped: not present)"
      continue
    fi
    to smartctl -H -i -A "$d" 2>&1
  done <<< "$devs"
  echo "(SMART/NVMe 健康数据需要 root：上面的 Permission denied 是预期现象，不代表磁盘有问题)"
}

ext4_state() {
  local d found=0
  if ! have tune2fs; then
    echo "(tune2fs 未安装：$(pkg_hint e2fsprogs) 后可检查 ext4 状态)"
    return 0
  fi
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    found=1
    echo "--- $d"
    to tune2fs -l "$d" 2>&1 | grep -iE 'filesystem state|mount count|check|error|features' \
      || echo "(tune2fs 没返回可用字段，很可能需要 root)"
  done < <(to findmnt -n -r -o SOURCE -t ext4 2>/dev/null)
  [ "$found" -eq 0 ] && echo "(没有 ext4 文件系统，或 findmnt 未返回任何设备)"
  return 0
}

journal_access() {
  local raw rc
  # 必须真读一条记录：-n 0 无论有没有权限都返回 0，不能用来判断
  raw="$(to journalctl -b -n1 --no-pager 2>&1)"; rc=$?
  if [ $rc -ne 0 ]; then
    echo "journalctl 执行失败 (rc=$rc)："
    printf '%s\n' "$raw" | head -2
  elif printf '%s' "$raw" | grep -qi 'not seeing messages'; then
    echo "journal 不可读：看不到其他用户的系统消息（需要 adm / systemd-journal 组或 root）"
    printf '%s\n' "$raw" | head -2
  else
    echo "journal 可读：能读到系统消息"
  fi
  return 0
}

default_gw() { to ip -4 route show default 2>/dev/null | awk '{print $3; exit}'; }

ping_host() { # ping_host <host>；无 IPv4 网关时传空字符串
  local h="${1:-}" out rc
  if [ -z "$h" ]; then
    echo "(没有目标地址，跳过 ping)"
    return 0
  fi
  if ! have ping; then
    echo "(ping 未安装，跳过)"
    return 0
  fi
  out="$(to ping -c 3 -W 2 "$h" 2>&1)"; rc=$?
  printf '%s\n' "$out" | tail -3
  [ $rc -ne 0 ] && printf '[ping exit=%d]\n' "$rc"
  return 0
}

colcon_check() {
  if ! have colcon; then
    echo "(colcon 未安装)"
    return 0
  fi
  echo "path=$(command -v colcon)"
  local ver
  ver="$(to pip3 show colcon-core 2>/dev/null | sed -n 's/^Version: //p')"
  echo "colcon-core version=${ver:-(pip3 里查不到)}"
  # 不调用 colcon version-check：它会联网查 PyPI（无网时挂住数分钟）且在当前目录写 log/，与只读约束冲突
  echo "(已跳过 colcon version-check：联网 + 写 log/，与只读约束冲突)"
  return 0
}

# 需要权限或未安装的探针：
#   预期内的限制（不是 root、没装、没有这个节点）→ 打印明确说明并返回 0，不记 [exit=N]
#   预期外的失败（有权限但命令真的出错）        → 返回非 0，照常记 [exit=N]
is_root() { [ "$(id -u)" -eq 0 ]; }

firewall_ufw() {
  if ! have ufw; then echo "(ufw 未安装)"; return 0; fi
  if ! is_root; then
    echo "(需要 root：ufw status 只有 root 能读，已跳过。这不代表没有防火墙——需要在 root 下执行 ufw status verbose)"
    return 0
  fi
  to ufw status verbose            # root 下真出错才把非 0 传给 try
}

firewall_nft() {
  if ! have nft; then echo "(nft 未安装)"; return 0; fi
  if ! have lsmod; then echo "(lsmod 缺失：无法判断模块是否已加载，为避免自动加载模块跳过)"; return 0; fi
  if ! lsmod | grep -q '^nf_tables'; then
    echo "(nf_tables 模块未加载：跳过，避免查询时自动加载模块)"; return 0
  fi
  if ! is_root; then
    echo "(需要 root：nft list ruleset 只有 root 能读（Operation not permitted），已跳过。这不代表没有规则)"
    return 0
  fi
  to nft list ruleset
}

firewall_iptables() {
  if ! have iptables; then echo "(iptables 未安装)"; return 0; fi
  if ! have lsmod; then echo "(lsmod 缺失：无法判断模块是否已加载，为避免自动加载模块跳过)"; return 0; fi
  if ! lsmod | grep -qE '^(ip_tables|nf_tables)'; then
    echo "(ip_tables/nf_tables 模块未加载：跳过，避免自动加载)"; return 0
  fi
  if ! is_root; then
    echo "(需要 root：iptables -L 只有 root 能读（Permission denied），已跳过。这不代表没有规则)"
    return 0
  fi
  to iptables -L -n -v
}

pip_config() {
  local out rc conf="${HOME:-/home/$(id -un)}/.config/pip/pip.conf"
  if ! have pip3; then echo "(pip3 未安装)"; return 0; fi
  out="$(to pip3 config list 2>&1)"; rc=$?
  if [ "$rc" -ne 0 ]; then printf '%s\n' "$out"; return "$rc"; fi
  if [ -n "$out" ]; then printf '%s\n' "$out"; else echo "(pip 没有任何 config：走默认源，无镜像/代理)"; fi
  echo "--- $conf"
  if [ -e "$conf" ]; then to cat "$conf"; else echo "(文件不存在)"; fi
}

conda_state() {
  if ! have conda; then echo "(conda 未安装：PATH 里没有 conda 命令，也不影响系统)"; return 0; fi
  to conda --version
}

ros2_env() {
  if compgen -G "/opt/ros/*" >/dev/null 2>&1; then
    to ls -1d /opt/ros/*
  else
    echo "(/opt/ros 下没有任何发行版)"
  fi
  echo "---"
  local vars
  vars="$(env | grep -iE '^ROS_|^AMENT_|^COLCON_' || true)"
  if [ -n "$vars" ]; then printf '%s\n' "$vars"
  else echo "(当前环境没有 ROS_/AMENT_/COLCON_ 变量：本 shell 未 source setup.bash，属正常)"; fi
  return 0
}

ros2_cli() {
  local d any=0
  for d in /opt/ros/*; do
    [ -f "$d/setup.bash" ] || continue
    any=1
    echo "--- $d"
    to bash -c "source '$d/setup.bash' && (ros2 --version 2>&1 || true) && echo ROS_DISTRO=\$ROS_DISTRO"
  done
  [ "$any" -eq 0 ] && echo "(没有可 source 的 /opt/ros/*/setup.bash，跳过)"
  return 0
}

rosdep_state() {
  if ! have rosdep; then echo "(rosdep 未安装)"; return 0; fi
  to rosdep --version
}

platform_profile_state() {
  local p=/sys/firmware/acpi/platform_profile
  local c=/sys/firmware/acpi/platform_profile_choices
  if [ -e "$p" ]; then to cat "$p"
  else echo "(本机 ACPI 无 platform_profile 节点：由内核驱动/固件管理，不是错误)"; fi
  [ -e "$c" ] && { printf 'choices='; to cat "$c"; }
  return 0
}

thermald_state() {
  if ! have systemctl; then echo "(systemctl 缺失)"; return 0; fi
  if ! systemctl list-unit-files thermald.service --no-legend 2>/dev/null | grep -q .; then
    echo "(未安装 thermald.service：AMD 平台通常不需要，功耗由 amd-pstate + power-profiles-daemon 管理)"
    return 0
  fi
  local st
  st="$(to systemctl is-active thermald 2>&1)"
  case "$st" in
    active)   echo "active（温度/风扇策略由 thermald 管理）" ;;
    inactive) echo "inactive（已安装但未运行，见 systemctl status thermald）" ;;
    *)        printf '%s\n' "$st" ;;
  esac
  return 0
}

dmesg_thermal() {
  local raw restrict
  if ! have dmesg; then echo "(dmesg 未安装)"; return 0; fi
  restrict="$(to cat /proc/sys/kernel/dmesg_restrict 2>/dev/null || echo 0)"
  case "$restrict" in ''|*[!0-9]*) restrict="$(to sysctl -n kernel.dmesg_restrict 2>/dev/null || echo 0)" ;; esac
  if [ "$restrict" = "1" ] && ! is_root; then
    echo "(kernel.dmesg_restrict=1：普通用户读不到内核日志，已跳过；内核日志见 journalctl -k -b)"
    return 0
  fi
  raw="$(to dmesg 2>&1)"; local rc=$?
  if [ "$rc" -ne 0 ]; then printf '%s\n' "$raw" | head -3; return "$rc"; fi
  local hits total
  hits="$(printf '%s\n' "$raw" | grep -iE 'thermal|throttl|mce|hardware error')"
  if [ -n "$hits" ]; then printf '%s\n' "$hits" | tail -60
  else
    total="$(printf '%s\n' "$raw" | grep -c . || true)"
    printf '(无匹配：已扫过 %s 行 dmesg，未出现热/硬件错误关键词)\n' "${total:-0}"
  fi
  return 0
}

http_probe() {
  # 出站探测：超时/连不上/DNS 失败都是「网络状况的结论」，不是探针故障，因此返回 0 并写明原因
  local spec h url out rc
  if ! have curl; then echo "(curl 未安装，跳过 HTTP 探测)"; return 0; fi
  # 只挑跨发行版都存在的目标：不做发行版镜像假设
  for spec in "github.com|https://github.com" "cloudflare.com|https://www.cloudflare.com/cdn-cgi/trace" "deb.debian.org|http://deb.debian.org/"; do
    h="${spec%%|*}"; url="${spec#*|}"
    out="$(to curl -sS -o /dev/null -w 'http=%{http_code} time=%{time_total}s' --max-time 8 "$url" 2>&1)"; rc=$?
    case "$rc" in
      0)  printf '%s OK %s\n' "$h" "$out" ;;
      28) printf '%s 超时：8s 内没传完（已收到部分数据），链路慢或被限速，不是脚本故障\n' "$h" ;;
      7)  printf '%s 无法连接：无路由或被拦截\n' "$h" ;;
      6)  printf '%s DNS 解析失败\n' "$h" ;;
      *)  printf '%s curl 返回 %d：%s\n' "$h" "$rc" "$(printf '%s' "$out" | head -1)" ;;
    esac
  done
  return 0
}

gpu_switch_state() {
  if ! have prime-select; then
    echo "(未安装 prime-select：本机未使用 NVIDIA prime 切换（或为固定独显/集显模式），不是错误)"
    return 0
  fi
  to prime-select query
}

have_version() { # have_version <命令> [版本参数]
  local c="$1" flag="${2:---version}"
  if ! have "$c"; then echo "($c 未安装或不在 PATH)"; return 0; fi
  echo "path=$(command -v "$c")"
  to "$c" "$flag"
}

###### 包管理器抽象 ##############################################
# 不假设发行版：按实际存在的包管理器给出安装提示 / 包状态，
# 认不出来就明说「未识别」，而不是假装是 apt 系统。

pkgmgr() { # -> apt | dnf | yum | pacman | zypper | apk | ""
  local m
  for m in apt-get dnf yum pacman zypper apk; do
    if have "$m"; then printf '%s' "$m"; return 0; fi
  done
  printf '%s' ""
}

pkg_hint() { # pkg_hint <包名...> -> 一行安装命令提示
  local pkgs="$*"
  case "$(pkgmgr)" in
    apt-get) printf 'apt install %s' "$pkgs" ;;
    dnf|yum) printf '%s install %s' "$(pkgmgr)" "$pkgs" ;;
    pacman)  printf 'pacman -S %s' "$pkgs" ;;
    zypper)  printf 'zypper install %s' "$pkgs" ;;
    apk)     printf 'apk add %s' "$pkgs" ;;
    *)       printf '（未识别包管理器，请用本发行版的安装方式装 %s）' "$pkgs" ;;
  esac
}

pkg_broken() { # 各包管理器的「依赖是否破损」检查
  case "$(pkgmgr)" in
    apt-get)
      echo "--- dpkg 状态异常（i 开头但第二列不是 i，排除正常的 rc/已删除留配置）:"
      to dpkg -l 2>/dev/null | awk '$1 ~ /^i[^i]$/ {print}' | head -20
      echo "--- apt-get -s check:"
      to apt-get -s check 2>&1 | tail -5
      ;;
    dnf)    to dnf check 2>&1 | tail -10 ;;
    yum)    to yum check 2>&1 | tail -10 ;;
    pacman) to pacman -Dk 2>&1 | tail -10 ;;
    zypper) to zypper --non-interactive verify --no-refresh 2>&1 | tail -10 ;;
    apk)    to apk audit 2>&1 | tail -10 ;;
    *)      echo "(未识别包管理器，跳过依赖完整性检查)" ;;
  esac
  return 0
}

pkg_held() { # 被 hold / 锁定、不随升级变动的包
  case "$(pkgmgr)" in
    apt-get) to apt-mark showhold ;;
    dnf)     to dnf versionlock list 2>&1 | tail -20 ;;
    yum)     to yum versionlock list 2>&1 | tail -20 ;;
    pacman)  to pacman -Qkk 2>&1 | head -5
             echo "(pacman 无 hold 概念；IgnorePkg 见 /etc/pacman.conf)"
             to grep -nE '^[[:space:]]*IgnorePkg' /etc/pacman.conf ;;
    zypper)  to zypper --non-interactive locks 2>&1 | tail -20 ;;
    *)       echo "(未识别包管理器，跳过)" ;;
  esac
  return 0
}

pkg_kernels() { # 已安装的内核包
  case "$(pkgmgr)" in
    apt-get) to dpkg -l 'linux-image-*' 2>/dev/null | awk '/^ii/ {print $2, $3}' ;;
    dnf|yum) to rpm -qa 'kernel*' 2>/dev/null | sort ;;
    pacman)  to pacman -Q 2>/dev/null | grep -E '^linux(-[a-z0-9]+)? ' ;;
    zypper)  to rpm -qa 'kernel-default*' 2>/dev/null | sort ;;
    apk)     to apk info -v 2>/dev/null | grep -E '^linux-' ;;
    *)       echo "(未识别包管理器，跳过)" ;;
  esac
  return 0
}

reboot_state() { # 是否需要重启（跨发行版）
  if [ -f /var/run/reboot-required ]; then
    echo "reboot REQUIRED"
    to cat /var/run/reboot-required 2>&1
    return 0
  fi
  if have needs-restarting; then
    to needs-restarting -r 2>&1   # dnf/yum 系
    return 0
  fi
  echo "no reboot required marker"
  return 0
}

proxy_conf() { # 各包管理器的代理配置
  local m; m="$(pkgmgr)"
  case "$m" in
    apt-get) to grep -rhiE 'proxy' /etc/apt/apt.conf.d/ /etc/apt/apt.conf 2>/dev/null ;;
    dnf|yum) to grep -iE 'proxy' /etc/dnf/dnf.conf /etc/yum.conf 2>/dev/null ;;
    pacman)  to grep -iE 'XferCommand|proxy' /etc/pacman.conf 2>/dev/null ;;
    zypper)  to grep -rhiE 'proxy' /etc/zypp/zypp.conf /etc/zypp/repos.d 2>/dev/null ;;
    *)       echo "(未识别包管理器，只检查了通用 proxy 环境变量)" ;;
  esac | grep -v '^$' || echo '(none)'
  return 0
}

compilers() { have_version gcc; have_version g++; }

venv_state() {
  if ! have python3; then echo "(python3 未安装或不在 PATH)"; return 0; fi
  if to python3 -m venv --help >/dev/null 2>&1; then echo "venv available"
  else echo "venv missing（python3-venv 未安装）"; fi
  return 0
}

npm_proxy() {
  if ! have npm; then echo "(npm 未安装或不在 PATH)"; return 0; fi
  to npm config get proxy
  to npm config get https-proxy
  to npm config get registry
}

git_proxy() {
  if ! have git; then echo "(git 未安装或不在 PATH)"; return 0; fi
  to git config --global --get http.proxy
  to git config --global --get https.proxy
  echo "(上面为空表示未设置代理)"
  return 0
}

docker_state() {
  if ! have docker; then echo "(docker 未安装或不在 PATH)"; return 0; fi
  to docker --version
  to systemctl is-active docker 2>/dev/null || echo "(docker 服务未运行或缺少 systemctl)"
  to docker info 2>&1 | head -20
  return 0
}

###### 分节主体 ################################################

sect_system() {
  echo "Linux System Health Audit - System / Hardware Information"
  echo "Generated: $DATE"
  echo "Audit mode: READ-ONLY | command timeout: ${TIMEOUT}s | sections: ${ONLY:-all}"
  try "Hostname / OS / Kernel" hostnamectl
  try "Kernel" uname -a
  try "OS release" cat /etc/os-release
  try "Uptime / load" uptime
  try "CPU model / topology" lscpu
  try "CPU flags (subset)" grep -m1 '^flags' /proc/cpuinfo
  try "Memory (free)" free -h
  try "Memory (meminfo)" cat /proc/meminfo
  try "Swap devices" swapon --show
  try "DMI / product (from sysfs)" sh -c 'for f in sys_vendor product_name product_version board_name bios_version bios_date; do p=/sys/class/dmi/id/$f; printf "%s=%s\n" "$f" "$(cat "$p" 2>&1)"; done'
  try "PCI devices" lspci -nnk
  try "GPU (nvidia-smi)" sh -c 'if [ -e /proc/driver/nvidia/version ]; then nvidia-smi; else echo "(NVIDIA 内核模块未加载；为保持只读不调用 nvidia-smi，避免自动加载模块)"; fi'
  try "GPU (lspci VGA/3D)" sh -c "lspci -nn | grep -Ei 'vga|3d|display'"
  try "NVIDIA driver version" cat /proc/driver/nvidia/version
  try "NVIDIA module params" sh -c 'for f in /proc/driver/nvidia/params /proc/driver/nvidia/gpus/*/information; do echo "--- $f"; cat "$f"; done'
  try "NVCC / CUDA" nvcc --version
  try "CUDA toolkit dirs" sh -c 'if ls -1d /usr/local/cuda* >/dev/null 2>&1; then ls -1d /usr/local/cuda*; echo "---"; ls /usr/local/cuda/bin 2>&1 | head; else echo "(未安装：/usr/local/cuda* 不存在；nvcc 可用与否见上一条)"; fi'
  try "USB devices" lsusb
  try "USB tree" lsusb -t
  try "USB controllers" sh -c "lspci -nn | grep -i usb"
  try "Block devices" lsblk -o NAME,MODEL,SERIAL,SIZE,ROTA,TYPE,FSTYPE,MOUNTPOINT
  try "BIOS/firmware version" sh -c 'cat /sys/class/dmi/id/bios_version 2>&1'
}

sect_hardware() {
  echo "Linux System Health Audit - Hardware Health (CPU/GPU/thermal/power)"
  echo "Generated: $DATE"
  echo "Audit mode: READ-ONLY | command timeout: ${TIMEOUT}s"
  try "lm-sensors" sensors
  try "sensors -u (raw)" sensors -u
  try "Thermal zones" sh -c 'for z in /sys/class/thermal/thermal_zone*; do printf "%s: type=%s temp=%s\n" "$z" "$(cat $z/type 2>/dev/null)" "$(cat $z/temp 2>/dev/null)"; done'
  try "Cooling devices" sh -c 'for c in /sys/class/thermal/cooling_device*; do printf "%s: type=%s cur=%s max=%s\n" "$c" "$(cat $c/type 2>/dev/null)" "$(cat $c/cur_state 2>/dev/null)" "$(cat $c/max_state 2>/dev/null)"; done'
  try "hwmon sensors" sh -c 'for h in /sys/class/hwmon/hwmon*; do echo "--- $h name=$(cat $h/name 2>/dev/null)"; for f in $h/temp*_input $h/temp*_label $h/fan*_input $h/fan*_label $h/pwm* $h/pwm*_enable $h/in*_input $h/power*_input $h/energy*_input; do [ -e "$f" ] && printf "%s = %s\n" "$(basename $f)" "$(cat $f 2>/dev/null)"; done; done; exit 0'
  try "CPU frequency policy" sh -c 'for p in /sys/devices/system/cpu/cpufreq/policy*; do echo "--- $p"; for f in scaling_driver scaling_governor scaling_available_governors scaling_min_freq scaling_max_freq cpuinfo_min_freq cpuinfo_max_freq scaling_cur_freq energy_performance_preference; do [ -e "$p/$f" ] && printf "%s=%s\n" "$f" "$(cat $p/$f 2>/dev/null)"; done; done'
  try "intel_pstate status" sh -c 'd=/sys/devices/system/cpu/intel_pstate; [ -d "$d" ] || { echo "(intel_pstate 不存在：AMD 平台用 amd-pstate，见上面 cpufreq policy 的 scaling_driver)"; exit 0; }; for f in "$d"/*; do printf "%s=%s\n" "$(basename "$f")" "$(cat "$f" 2>/dev/null)"; done'
  try "CPU idle states" sh -c 'for s in /sys/devices/system/cpu/cpu0/cpuidle/state*; do printf "%s: name=%s desc=%s disable=%s usage=%s time=%s\n" "$s" "$(cat $s/name)" "$(cat $s/desc)" "$(cat $s/disable)" "$(cat $s/usage)" "$(cat $s/time)"; done'
  try "RAPL powercap" sh -c 'for d in /sys/class/powercap/*; do echo "--- $d"; cat $d/name 2>/dev/null; cat $d/energy_uj 2>/dev/null; cat $d/max_energy_range_uj 2>/dev/null; done'
  try "Platform profile (ACPI)" platform_profile_state
  try "Battery / power supplies" sh -c 'for b in /sys/class/power_supply/*; do echo "--- $b"; for f in type status capacity capacity_level charge_full charge_now charge_full_design energy_full energy_now energy_full_design voltage_now voltage_min_design power_now current_now cycle_count health manufacturer model_name technology present; do [ -e "$b/$f" ] && printf "%s=%s\n" "$f" "$(cat $b/$f 2>/dev/null)"; done; done; exit 0'
  try "upower dump" upower -d
  try "TLP status" tlp-stat -s
  try "power-profiles-daemon" powerprofilesctl get
  try "thermald" thermald_state
  try_grep "Thermal / hardware error kernel messages" 'thermal|throttl|temperature|mce|hardware error|microcode|critical temp|overheat' journalctl -k -b --no-pager
  try "dmesg thermal (may need root)" dmesg_thermal
  try "Package temp samples (3x1s)" sh -c 'for i in 1 2 3; do for z in /sys/class/thermal/thermal_zone*; do t=$(cat $z/type 2>/dev/null); v=$(cat $z/temp 2>/dev/null); case "$t" in x86_pkg_temp|acpitz) echo "$(date +%T) $t=${v}";; esac; done; sleep 1; done'
  try_tail "Top CPU consumers" 20 ps -eo pid,comm,%cpu,%mem --sort=-%cpu
  try_tail "Top memory consumers" 20 ps -eo pid,comm,%cpu,%mem --sort=-%mem
  try "GPU processes" sh -c 'if [ -e /proc/driver/nvidia/version ]; then nvidia-smi --query-compute-apps=pid,process_name,used_memory --format=csv 2>&1; nvidia-smi --query-gpu=name,temperature.gpu,utilization.gpu,power.draw,power.limit,clocks.gr,clocks.mem,clocks_throttle_reasons.active,persistence_mode,driver_version --format=csv 2>&1; else echo "(NVIDIA 模块未加载，跳过)"; fi'
  try "Prime / GPU switching" gpu_switch_state
}

sect_storage() {
  echo "Linux System Health Audit - Storage Health"
  echo "Generated: $DATE"
  echo "Audit mode: READ-ONLY (SMART may require root; unreadable data noted) | timeout: ${TIMEOUT}s"
  try "Block devices" lsblk -o NAME,MODEL,SERIAL,SIZE,ROTA,TYPE,FSTYPE,FSVER,LABEL,UUID,MOUNTPOINT
  try "Filesystems / usage" df -hT
  try "Inode usage" df -i
  try "Mounts" findmnt
  try "/etc/fstab" cat /etc/fstab
  try "SMART (all disks, may need root)" smart_all
  try "NVMe SMART log (may need root)" sh -c 'found=0; for c in /sys/class/nvme/nvme*; do [ -e "$c" ] || continue; n=$(basename "$c"); d=/dev/$n; found=1; echo "--- $d"; if [ -r "$d" ]; then nvme smart-log "$d" 2>&1; else echo "(节点不可读：NVMe SMART 需要 root；Permission denied 不代表硬盘异常)"; fi; done; [ "$found" -eq 0 ] && echo "(没有找到 NVMe 控制器)"; exit 0'
  try_grep "Disk errors in kernel log" 'I/O error|ata[0-9]|nvme|ext4-fs error|btrfs|filesystem error|bad sector|medium error|SATA link|reset' journalctl -k -b --no-pager
  try "Filesystem state (ext4)" ext4_state
  try "SMART daemon" systemctl is-active smartmontools
  try "Disk temperature" sh -c 'for h in /sys/class/hwmon/hwmon*; do n=$(cat $h/name 2>/dev/null); [ "$n" = "nvme" ] && { echo "--- $h"; cat $h/temp1_input 2>/dev/null; }; done; exit 0'
  try "Swap" swapon --show
  try "TRIM timer" systemctl is-enabled fstrim.timer
  try "Filesystem disk space critical check" sh -c "df -P | awk 'NR==1 || (\$1 ~ /^\\/dev\\// && \$2 >= 1048576 && \$5+0 >= 80)'"
}

sect_services() {
  echo "Linux System Health Audit - Services / Kernel / Logs"
  echo "Generated: $DATE"
  echo "Audit mode: READ-ONLY | timeout: ${TIMEOUT}s"
  try "Failed system units" systemctl --failed --no-pager
  try "Failed user units" systemctl --user --failed --no-pager
  try "Running services" systemctl list-units --type=service --state=running --no-pager
  try "Enabled services" systemctl list-unit-files --type=service --state=enabled --no-pager
  try "Boot time" systemd-analyze
  try_tail "Boot blame (top)" 25 systemd-analyze blame
  try_grep "Kernel ring buffer errors" 'error|fail|warn|bug|oops|panic|call trace' journalctl -k -b --no-pager
  try_tail "Journal priority err (this boot)" 150 journalctl -b -p err --no-pager
  try_tail "Journal priority warning (this boot)" 120 journalctl -b -p warning --no-pager
  try "Journal read permission test" journal_access
  try "Crash / oops history" sh -c "ls -la /var/crash 2>&1; echo '---'; ls -la /var/lib/systemd/coredump 2>&1 | tail -20"
  try_tail "Recent reboots" 10 last -x reboot
  try "Kernel taint" cat /proc/sys/kernel/tainted
  try_tail "Loaded modules (non-standard?)" 80 lsmod
  try_grep "OOM events" 'out of memory|oom-kill|killed process' journalctl -k -b --no-pager
  try "Time sync" timedatectl
  try "systemd journal disk usage" journalctl --disk-usage
  try "time sync status" sh -c "timedatectl show -p NTPSynchronized --value; chronyc tracking 2>&1 | head -20"
}

sect_network() {
  echo "Linux System Health Audit - Network / DNS / Proxy / Dev Environment"
  echo "Generated: $DATE"
  echo "Audit mode: READ-ONLY | timeout: ${TIMEOUT}s"
  try "Interfaces" ip -br a
  try "Addresses" ip a
  try "Routes" ip r
  try "Route cache / rules" sh -c "ip rule; echo '---'; ip -6 r"
  try "Link stats" ip -s link
  try "Resolv.conf" cat /etc/resolv.conf
  try "Resolved status" resolvectl status
  try "Hosts file" cat /etc/hosts
  try "NetworkManager status" nmcli -t -f DEVICE,TYPE,STATE,CONNECTION device status
  try "NetworkManager connectivity" nmcli networking connectivity
  try "Wireless" sh -c "nmcli -f IN-USE,SSID,SIGNAL,SECURITY dev wifi list --rescan no 2>&1 | head -20"
  try "Listening sockets" ss -tulpn
  try "Socket summary" ss -s
  try "Proxy env vars" sh -c "env | grep -iE 'proxy|no_proxy' || echo '(none set)'"
  try "Package manager proxy config" proxy_conf
  try "Git proxy config" git_proxy
  try "npm proxy/registry" npm_proxy
  try "pip config" pip_config
  try "Firewall (ufw)" firewall_ufw
  try "nftables rules" firewall_nft
  try "iptables (may need root)" firewall_iptables
  try "DNS resolution test" sh -c "getent hosts github.com; getent hosts deb.debian.org; getent hosts registry.npmjs.org"
  try "Connectivity test (HTTP)" http_probe
  try "Ping gateway" ping_host "$(default_gw)"
  try "Ping public DNS" ping_host 1.1.1.1
  try "Interface errors/drops" sh -c "for i in /sys/class/net/*; do n=\$(basename \$i); [ \"\$n\" = lo ] && continue; echo \"\$n rx_err=\$(cat \$i/statistics/rx_errors) rx_drop=\$(cat \$i/statistics/rx_dropped) tx_err=\$(cat \$i/statistics/tx_errors) tx_drop=\$(cat \$i/statistics/tx_dropped)\"; done"
  try "USB network devices" sh -c "lsusb | grep -iE 'ethernet|wireless|bluetooth|wifi'"
  echo
  echo "===== Development Environment ====="
  try "Node.js" have_version node -v
  try "npm" have_version npm -v
  try "nvm" sh -c 'ls -d ~/.nvm 2>&1; if [ -s ~/.nvm/nvm.sh ]; then echo "(nvm 是 shell 函数、不在 PATH；要查版本需先 source ~/.nvm/nvm.sh——为保持只读这里不执行)"; else echo "(未发现 ~/.nvm/nvm.sh)"; fi'
  try "Python 3" have_version python3
  try "Python (default)" have_version python
  try "pip" have_version pip3
  try "conda" conda_state
  try "virtualenv/venv" venv_state
  try "gcc / g++" compilers
  try "cmake" have_version cmake
  try "git" have_version git
  try "ROS2 installs" ros2_env
  try "ROS2 version / CLI" ros2_cli
  try "colcon" colcon_check
  try "rosdep" rosdep_state
  try "Docker" docker_state
  try "Docker group membership" sh -c "id; getent group docker"
  try "Disk space for dev (/home)" df -h /home
  try_tail "Installed snap packages (top)" 40 sh -c 'command -v snap >/dev/null || { echo "(snap 未安装，跳过)"; exit 0; }; snap list'
  try "Broken packages" pkg_broken
  try "Held packages" pkg_held
  try "Kernel version packages" pkg_kernels
  try "Reboot required" reboot_state
}

###### 运行器 ##################################################

size_of() {
  if have stat; then
    stat -c %s "$1" 2>/dev/null || echo "?"
  else
    wc -c < "$1" 2>/dev/null | tr -d ' '
  fi
}

cleanup() { rm -f "$OUT"/.*.tmp."$$" 2>/dev/null || true; }
trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM

run_section() { # run_section <id> <文件名> <函数名>
  local id="$1" file="$2" fn="$3"
  local tmp="$OUT/.$file.tmp.$$"
  local rc=0 fails=0

  # 子 shell 隔离：某节里出现未定义变量/意外退出，只损失这一节，不影响其余分节
  ( "$fn" ) > "$tmp" 2>&1 || rc=$?

  # 正常分节最后一个语句是 try()（恒返回 0），所以 rc!=0 一定是异常退出。
  # 此时不发布半截结果：既保留上一次的完整报告，也不把错误信息伪装成报告内容。
  if [ "$rc" -ne 0 ]; then
    printf 'FAILED: %-18s 本节异常退出 rc=%d，未发布半截结果（保留上一次的文件）\n' "$file" "$rc"
    tail -3 "$tmp" 2>/dev/null | sed 's/^/        | /'
    rm -f "$tmp"
    WRITE_FAILS=$((WRITE_FAILS + 1))
    return 0
  fi

  if [ ! -s "$tmp" ]; then
    rm -f "$tmp"
    printf 'FAILED: %-18s 本节没有产生任何输出，保留上一次的文件\n' "$file"
    WRITE_FAILS=$((WRITE_FAILS + 1))
    return 0
  fi

  fails="$(grep -c '^\[exit=[0-9][0-9]*\]' "$tmp" 2>/dev/null || true)"
  fails="${fails:-0}"
  mv -f "$tmp" "$OUT/$file"
  TOTAL_PROBE_FAILS=$((TOTAL_PROBE_FAILS + fails))
  printf 'Wrote:  %-18s %8s bytes  (%s 处采集失败)\n' \
    "$file" "$(size_of "$OUT/$file")" "$fails"
  return 0
}

preflight() {
  [ -d "$OUT" ] || mkdir -p "$OUT" 2>/dev/null || die "无法创建输出目录：$OUT"
  [ -w "$OUT" ] || die "输出目录不可写：$OUT"

  local c missing_essential="" missing_optional=""
  for c in awk sed grep date tr head tail wc; do
    command -v "$c" >/dev/null 2>&1 || missing_essential="$missing_essential $c"
  done
  [ -n "$missing_essential" ] && die "缺少必需命令：$missing_essential"

  for c in timeout lsblk findmnt systemctl journalctl df ps; do
    command -v "$c" >/dev/null 2>&1 || missing_optional="$missing_optional $c"
  done
  if [ -n "$missing_optional" ]; then
    printf 'warning: 以下命令缺失，相关分节会显示 [exit=127]：%s\n' "$missing_optional" >&2
  fi
}

###### 入口 ####################################################

while [ $# -gt 0 ]; do
  case "$1" in
    --outdir)    [ $# -ge 2 ] || die "--outdir 需要一个目录参数"; OUT="$2"; shift 2 ;;
    --outdir=*)  OUT="${1#*=}"; shift ;;
    --section)   [ $# -ge 2 ] || die "--section 需要一个参数"; add_section "$2"; shift 2 ;;
    --section=*) add_section "${1#*=}"; shift ;;
    --timeout)   [ $# -ge 2 ] || die "--timeout 需要一个秒数"; TIMEOUT="$2"; shift 2 ;;
    --timeout=*) TIMEOUT="${1#*=}"; shift ;;
    --strict)    STRICT=1; shift ;;
    --list)      list_sections; exit 0 ;;
    -h|--help)   usage; exit 0 ;;
    *)           die "未知参数：$1（用 --help 查看用法）" ;;
  esac
done

case "$TIMEOUT" in
  ''|*[!0-9]*) die "--timeout 必须是正整数秒，收到：$TIMEOUT" ;;
esac
[ "$TIMEOUT" -ge 1 ] || die "--timeout 必须 ≥ 1"

preflight

printf 'audit: outdir=%s timeout=%ss sections=%s\n' "$OUT" "$TIMEOUT" "${ONLY:-all}"

if want system;   then run_section system   system-info.txt sect_system;   fi
if want hardware; then run_section hardware hardware.txt    sect_hardware; fi
if want storage;  then run_section storage  storage.txt     sect_storage;  fi
if want services; then run_section services services.txt    sect_services; fi
if want network;  then run_section network  network.txt     sect_network;  fi

printf '\n合计：%d 节写出失败，%d 处采集命令失败（[exit=N]）。\n' "$WRITE_FAILS" "$TOTAL_PROBE_FAILS"

if [ "$WRITE_FAILS" -gt 0 ]; then exit 1; fi
if [ "$STRICT" -eq 1 ] && [ "$TOTAL_PROBE_FAILS" -gt 0 ]; then exit 3; fi
exit 0
