#!/usr/bin/env bash
# ============================================================
# Claude Code hook: 系统健康检查 / 危险命令拦截
#
# 只读探测，不修改任何系统状态，不创建任何文件。
#
# 支持两个事件（由 stdin 的 hook_event_name 决定）：
#
#   1) SessionStart  —— 会话开始时跑一次轻量健康检查（目标 < 3 秒）
#                       有问题才输出 additionalContext，没问题静默
#
#   2) PreToolUse    —— 在 Bash 工具执行前拦截已知的破坏性命令
#                       （chown/chmod -R /、rm -rf /、dd 写裸盘、mkfs/wipefs）
#
# 本脚本默认未启用，安装方式见 docs/claude-health-hook.md。
#
# 测试：
#   bash tests/test-claude-health-hook.sh
#
# 退出码约定（Claude Code 规范）：
#   0 = 正常（JSON 生效）；脚本内部任何失败都退化为静默放行，不阻断用户
# ============================================================
set -uo pipefail

# ---------- 读取 stdin ----------
INPUT="$(cat 2>/dev/null || true)"

# 一次 python3 调用解析出事件名、工具名、命令，用 NUL 分隔避免换行/空格问题
parse_input() {
  printf '%s' "$INPUT" | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    d = {}
def get(*keys):
    cur = d
    for k in keys:
        if not isinstance(cur, dict) or k not in cur:
            return ""
        cur = cur[k]
    return cur if isinstance(cur, str) else ""
for v in (get("hook_event_name"), get("tool_name"), get("tool_input", "command")):
    sys.stdout.write(v.replace("\0", "") + "\0")
' 2>/dev/null
}

FIELDS=()
while IFS= read -r -d '' _f; do FIELDS+=("$_f"); done < <(parse_input)
EVENT="${FIELDS[0]:-}"
TOOL="${FIELDS[1]:-}"
CMD="${FIELDS[2]:-}"

# 没有事件名时（手工执行、测试）默认走健康检查
[ -z "$EVENT" ] && EVENT="SessionStart"

# ---------- 工具函数 ----------
have() { command -v "$1" >/dev/null 2>&1; }

# 带超时的命令，超时/失败都返回空，调用方自行处理
tmo() { # tmo <seconds> <cmd...>
  local secs="$1"; shift
  if have timeout; then
    timeout "$secs" "$@" 2>/dev/null
  else
    "$@" 2>/dev/null
  fi
}

json_escape() {
  python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))' 2>/dev/null
}

# ============================================================
# 事件 1：SessionStart 健康检查
# ============================================================
run_health_check() {
  local issues=()
  local infos=()

  # --- 1. 根目录属主（被改成普通用户会让 systemd-tmpfiles 拒绝清理 /tmp、/run） ---
  local root_owner
  root_owner="$(stat -c '%U' / 2>/dev/null || echo unknown)"
  if [ "$root_owner" != "root" ]; then
    issues+=("【高】/ 属主是 ${root_owner}，不是 root。会导致 systemd-tmpfiles 拒绝清理 /tmp、/run、/var/log，且普通用户可写根目录。修复：sudo chown root:root / （不要加 -R）")
  fi

  # --- 2. 失败的 systemd 单元 ---
  local failed
  failed="$(tmo 3 systemctl --failed --no-legend --plain --no-pager | awk '{print $1}' | grep -v '^$' | head -6)"
  if [ -n "$failed" ]; then
    local failed_list
    failed_list="$(printf '%s' "$failed" | tr '\n' ' ')"
    # 已知的低影响服务：只失败这一个时降级为提示，不当作问题。
    # 想加自己的，设 HEALTH_LOW_IMPACT="foo.service bar.service"（空格分隔，匹配前缀）
    local low_impact="${HEALTH_LOW_IMPACT:-apport-autoreport}"
    local only_low=1 s
    for s in $failed; do
      case " $low_impact " in *" $s "*) ;; *) only_low=0 ;; esac
    done
    if [ "$only_low" -eq 1 ]; then
      infos+=("低影响服务失败：${failed_list}")
    else
      issues+=("【中】失败的服务：${failed_list}")
    fi
  fi

  # --- 3. 磁盘空间 ---
  local df_out
  df_out="$(tmo 3 df -P / /home | awk 'NR>1 && $5+0 >= 85 {printf "%s %s(%s可用)", $6, $5, $4}')"
  if [ -n "$df_out" ]; then
    issues+=("【中】磁盘使用率过高：${df_out}")
  fi

  # --- 4. 本次启动的 USB 枚举错误（摄像头重试风暴） ---
  if have journalctl; then
    local usb_err
    usb_err="$(tmo 4 journalctl -k -b 0 --no-pager | grep -c 'error -71' || true)"
    usb_err="${usb_err:-0}"
    if [ "$usb_err" -ge 100 ] 2>/dev/null; then
      issues+=("【中】本次启动 USB 协议错误 ${usb_err} 条（-71 = 设备枚举失败重试），会拖慢开机并可能踢掉键鼠；查 dmesg 定位具体设备")
    elif [ "$usb_err" -ge 20 ] 2>/dev/null; then
      infos+=("本次启动 USB 协议错误 ${usb_err} 条")
    fi
  fi

  # --- 5. CPU 温度 ---
  if have sensors; then
    local tctl
    tctl="$(tmo 3 sensors | awk '/Tctl:/ {gsub(/[+°C]/,"",$2); print int($2); exit}')"
    if [ -n "$tctl" ] && [ "$tctl" -ge 90 ] 2>/dev/null; then
      issues+=("【中】CPU Tctl ${tctl}°C 偏高")
    fi
  fi

  # --- 6. 需要重启 ---
  if [ -f /var/run/reboot-required ]; then
    infos+=("系统标记需要重启（/var/run/reboot-required）")
  fi

  # --- 7. Timeshift 快照数量（保留策略是否生效）---
  # 快照目录可用 TIMESHIFT_SNAPSHOTS 覆盖（默认从 timeshift.json 读，读不到就用常见路径）。
  local snap_dir="${TIMESHIFT_SNAPSHOTS:-}"
  if [ -z "$snap_dir" ]; then
    snap_dir="$(sed -n 's/.*"snapshot_device"[^,]*"\(.*\)".*/\1/p' /etc/timeshift/timeshift.json 2>/dev/null | head -1)"
    [ -n "$snap_dir" ] && snap_dir="$snap_dir/timeshift/snapshots"
  fi
  [ -n "$snap_dir" ] || snap_dir=/timeshift/snapshots
  if [ -d "$snap_dir" ]; then
    local snap_count keep
    snap_count="$(find "$snap_dir" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)"
    keep="$(grep -oE '"count_daily"[[:space:]]*:[[:space:]]*"?[0-9]+"?' /etc/timeshift/timeshift.json 2>/dev/null | grep -oE '[0-9]+' | head -1)"
    if [ -n "$keep" ] && [ "$snap_count" -gt $((keep + 2)) ] 2>/dev/null; then
      issues+=("【低】Timeshift 有 ${snap_count} 份快照（$snap_dir），超过 count_daily=${keep}")
    fi
  fi

  # --- 输出 ---
  if [ $(( ${#issues[@]} + ${#infos[@]} )) -eq 0 ]; then
    exit 0   # 一切正常，静默
  fi

  local msg="系统健康检查（只读，$(date '+%F %H:%M')）"
  local i
  if [ "${#issues[@]}" -gt 0 ]; then
    msg+=$'\n'"需要注意："
    for i in "${issues[@]}"; do msg+=$'\n'"  - ${i}"; done
  fi
  if [ "${#infos[@]}" -gt 0 ]; then
    msg+=$'\n'"提示："
    for i in "${infos[@]}"; do msg+=$'\n'"  - ${i}"; done
  fi

  local esc
  esc="$(printf '%s' "$msg" | json_escape)"
  [ -z "$esc" ] && exit 0
  printf '{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":%s}}\n' "$esc"
}

# ============================================================
# 事件 2：PreToolUse 危险命令拦截
# ============================================================
run_pretool_guard() {
  [ "$TOOL" != "Bash" ] && exit 0
  [ -z "$CMD" ] && exit 0

  local reason=""

  # 根目录本身：/、//、/*、/*/（不是 /tmp、/home/... 这类子路径）
  local root_target='(^|[[:space:]])/{1,2}\*?/?([[:space:]]|$)'
  # 块设备的各种写法：裸盘、分区、/dev/disk/by-*、/dev/mapper/*
  local blk_dev='(/dev/(nvme[0-9]+n[0-9]+(p[0-9]+)?|sd[a-z][0-9]*|vd[a-z][0-9]*|mmcblk[0-9]+(p[0-9]+)?|disk/[a-z-]+/[^[:space:]]+|mapper/[^[:space:]]+)|/dev/disk/by-[a-z]+/[^[:space:]]+)'

  # chown/chmod 递归作用于根目录
  if printf '%s' "$CMD" | grep -qE '(^|[[:space:]])(chown|chmod)[[:space:]]' &&
     printf '%s' "$CMD" | grep -qE '(-[a-zA-Z]*R[a-zA-Z]*|--recursive)' &&
     printf '%s' "$CMD" | grep -qE "$root_target"; then
    reason="递归 chown/chmod 作用在根目录，会破坏整个系统的属主/权限。如果只是修复 / 本身，去掉 -R。"
  fi

  # rm -r 作用于根目录
  if [ -z "$reason" ] &&
     printf '%s' "$CMD" | grep -qE '(^|[;&|[:space:]/])rm[[:space:]]' &&
     printf '%s' "$CMD" | grep -qE '(-[a-zA-Z]*[rR][a-zA-Z]*|--recursive)' &&
     { printf '%s' "$CMD" | grep -qE "$root_target" || printf '%s' "$CMD" | grep -q -- '--no-preserve-root'; }; then
    reason="递归删除根目录内容，会清空系统。"
  fi

  # dd 直接写裸盘或分区
  if [ -z "$reason" ] &&
     printf '%s' "$CMD" | grep -qE "of=${blk_dev}"; then
    reason="dd 直接写裸盘/分区，会覆盖分区表或文件系统。"
  fi

  # mkfs / wipefs 作用于块设备（wipefs -n 是 dry-run，放行）
  if [ -z "$reason" ] &&
     ! printf '%s' "$CMD" | grep -qE 'wipefs[[:space:]]+(-[a-zA-Z]*n[a-zA-Z]*|--no-act)([[:space:]]|$)' &&
     printf '%s' "$CMD" | grep -qE "(mkfs(\.[a-z0-9]+)?|mke2fs|wipefs)[[:space:]].*${blk_dev}"; then
    reason="格式化/擦除块设备，会销毁其上所有数据。确认目标盘没有挂载且数据已备份。"
  fi

  [ -z "$reason" ] && exit 0

  local esc
  esc="$(printf '%s' "$reason" | json_escape)"
  [ -z "$esc" ] && exit 0
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":%s}}\n' "$esc"
}

# ============================================================
case "$EVENT" in
  SessionStart) run_health_check ;;
  PreToolUse)   run_pretool_guard ;;
  *)            exit 0 ;;
esac
