#!/usr/bin/env bash
# ============================================================
# health-hook.sh 的测试（不安装 hook，纯本地喂 JSON 验证行为）
#
# 运行：bash tests/test-claude-health-hook.sh
#
# 覆盖：
#   SessionStart  —— 能输出合法 JSON，或正常时静默
#   PreToolUse    —— 危险命令必须 deny，安全命令必须放行
#   健壮性        —— 空输入、坏 JSON、非 Bash 工具都必须 exit 0 且不崩
# ============================================================
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$DIR/../bin/claude-health-hook.sh"
PASS=0
FAIL=0
FAILED_NAMES=()

# ---------- 断言 ----------
ok()   { PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); FAILED_NAMES+=("$1"); printf '  \033[31mFAIL\033[0m %s\n' "$1"; [ -n "${2:-}" ] && printf '        %s\n' "$2"; }

json_valid() { printf '%s' "$1" | python3 -c 'import sys,json; json.load(sys.stdin)' 2>/dev/null; }

field() { # field <json> <python-expr on d>
  printf '%s' "$1" | python3 -c "
import sys, json
try: d = json.load(sys.stdin)
except Exception: sys.exit(1)
print($2)
" 2>/dev/null
}

RC=0
HOOK_OUT=""
run_hook() { # run_hook <json> -> 设置全局 HOOK_OUT 与 RC（不能用命令替换，否则 RC 丢失）
  HOOK_OUT="$(printf '%s' "$1" | timeout 20 bash "$HOOK" 2>/dev/null)"
  RC=$?
}

section() { printf '\n\033[1m%s\033[0m\n' "$1"; }

# ============================================================
section "1. 语法与可执行性"
# ============================================================
if bash -n "$HOOK" 2>/dev/null; then ok "bash -n 通过"; else bad "bash -n 失败"; fi
[ -x "$HOOK" ] && ok "脚本可执行" || bad "脚本不可执行（chmod +x 未做）"

# ============================================================
section "2. SessionStart 健康检查"
# ============================================================
SS_JSON='{"session_id":"test","transcript_path":"/tmp/t.jsonl","cwd":"/home/user","hook_event_name":"SessionStart","source":"startup","model":"claude-opus-5"}'

run_hook "$SS_JSON"
OUT="$HOOK_OUT"
if [ "$RC" -eq 0 ]; then ok "exit 0"; else bad "exit 0" "rc=$RC"; fi

if [ -z "$OUT" ]; then
  ok "当前系统健康，静默输出（无 additionalContext）"
else
  if json_valid "$OUT"; then
    ok "输出是合法 JSON"
  else
    bad "输出不是合法 JSON" "$OUT"
  fi
  EV="$(field "$OUT" "d['hookSpecificOutput']['hookEventName']")"
  [ "$EV" = "SessionStart" ] && ok "hookEventName = SessionStart" || bad "hookEventName 错误" "$EV"
  CTX="$(field "$OUT" "d['hookSpecificOutput']['additionalContext']")"
  [ -n "$CTX" ] && ok "additionalContext 非空（$(printf '%s' "$CTX" | head -1) ...）" || bad "additionalContext 为空"
  # systemctl 在非 --plain 模式下会给失败单元加 "●" 前缀，必须不出现
  if printf '%s' "$CTX" | grep -q '●'; then
    bad "失败服务名没有 ● 前缀" "缺少 --plain：$(printf '%s' "$CTX" | grep '●')"
  else
    ok "失败服务名没有 ● 前缀"
  fi
fi

# 空 stdin 应默认走健康检查且 exit 0
OUT="$(printf '' | timeout 20 bash "$HOOK" 2>/dev/null)"; RC=$?
[ "$RC" -eq 0 ] && ok "空 stdin：exit 0（默认走健康检查）" || bad "空 stdin：exit 0" "rc=$RC"
if [ -n "$OUT" ] && ! json_valid "$OUT"; then bad "空 stdin 输出不是合法 JSON" "$OUT"; else ok "空 stdin 输出合法或静默"; fi

# 坏 JSON 应静默放行
OUT="$(printf 'not json at all' | timeout 20 bash "$HOOK" 2>/dev/null)"; RC=$?
[ "$RC" -eq 0 ] && ok "坏 JSON：exit 0，不崩" || bad "坏 JSON：exit 0" "rc=$RC"

# ============================================================
section "3. PreToolUse —— 必须 deny 的破坏性命令"
# ============================================================
deny_case() { # deny_case <名称> <命令>
  local name="$1" cmd="$2"
  local payload out
  payload="$(python3 -c '
import json, sys
print(json.dumps({"session_id":"t","cwd":"/home/user","hook_event_name":"PreToolUse",
                  "tool_name":"Bash","tool_input":{"command":sys.argv[1]},"tool_use_id":"toolu_x"}))
' "$cmd")"
  run_hook "$payload"
  local out="$HOOK_OUT"
  if [ "$RC" -ne 0 ]; then bad "$name" "rc=$RC，应为 0"; return; fi
  if [ -z "$out" ]; then bad "$name" "没有输出，未拦截"; return; fi
  if ! json_valid "$out"; then bad "$name" "输出不是合法 JSON: $out"; return; fi
  local dec
  dec="$(field "$out" "d['hookSpecificOutput']['permissionDecision']")"
  [ "$dec" = "deny" ] && ok "$name → deny" || bad "$name" "permissionDecision=$dec"
}

deny_case "chown -R root:root /"          'sudo chown -R root:root /'
deny_case "chmod -R 755 /*"               'chmod -R 755 /*'
deny_case "chown --recursive user /"     'chown --recursive user /'
deny_case "rm -rf /"                      'sudo rm -rf /'
deny_case "rm -rf /* 带前缀命令"           'cd /tmp && rm -rf /*'
deny_case "rm -fr --no-preserve-root /"   'rm -fr --no-preserve-root /'
deny_case "dd 写 nvme 裸盘"                'sudo dd if=/dev/zero of=/dev/nvme0n1 bs=1M'
deny_case "dd 写分区"                      'dd if=x.img of=/dev/nvme1n1p2'
deny_case "dd 写 sda"                      'dd if=/dev/zero of=/dev/sda bs=4M'
deny_case "mkfs.ext4 /dev/nvme0n1p3"      'sudo mkfs.ext4 /dev/nvme0n1p3'
deny_case "wipefs -a /dev/sdb"            'sudo wipefs -a /dev/sdb'
deny_case "chmod 755 -R /（参数顺序不同）" 'chmod 755 -R /'
deny_case "rm -rf //"                     'sudo rm -rf //'
deny_case "rm -rf /*/"                    'sudo rm -rf /*/'
deny_case "dd of=/dev/disk/by-id"         'dd if=x.img of=/dev/disk/by-id/nvme-Samsung_X'
deny_case "mkfs 用 UUID 路径"              'sudo mkfs.ext4 /dev/disk/by-uuid/1234-ABCD'

# ============================================================
section "4. PreToolUse —— 必须放行的正常命令"
# ============================================================
allow_case() { # allow_case <名称> <命令>
  local name="$1" cmd="$2"
  local payload out
  payload="$(python3 -c '
import json, sys
print(json.dumps({"session_id":"t","cwd":"/home/user","hook_event_name":"PreToolUse",
                  "tool_name":"Bash","tool_input":{"command":sys.argv[1]},"tool_use_id":"toolu_x"}))
' "$cmd")"
  run_hook "$payload"
  local out="$HOOK_OUT"
  if [ "$RC" -ne 0 ]; then bad "$name" "rc=$RC，应为 0"; return; fi
  if [ -n "$out" ]; then bad "$name" "被误拦: $out"; return; fi
  ok "$name → 放行"
}

allow_case "chown root:root /（本次修复用的命令）" 'sudo chown root:root /'
allow_case "chown -R user ~/Projects"            'chown -R user:user /home/user/Projects'
allow_case "chmod -R 755 /home/user/tools"       'chmod -R 755 /home/user/tools'
allow_case "rm -rf /tmp/build"                    'rm -rf /tmp/build'
allow_case "rm -rf ~/.cache/uv"                   'rm -rf ~/.cache/uv'
allow_case "dd 写镜像文件"                         'dd if=/dev/zero of=/home/user/test.img bs=1M count=10'
allow_case "df / ls / stat"                       'df -h / && ls / && stat -c %U /'
allow_case "find / -name x"                       'find / -maxdepth 2 -name "*.log"'
allow_case "mount 查看"                            'mount | grep nvme'
allow_case "blkid"                                'sudo blkid'
allow_case "rm -rf /tmp/*（通配子目录）"             'rm -rf /tmp/*'
allow_case "rm -rf /home/user/build/*"              'rm -rf /home/user/build/*'
allow_case "dd 写 /dev/null"                          'dd if=/dev/zero of=/dev/null bs=1M count=10'
allow_case "mkfs 普通镜像文件"                         'mkfs.ext4 /home/user/test.img'
allow_case "lsblk 查盘"                                'lsblk /dev/nvme0n1'
allow_case "smartctl 只读查询"                         'sudo smartctl -a /dev/nvme1n1'
allow_case "wipefs -n（dry-run）"                      'sudo wipefs -n /dev/sdb'
allow_case "rsync 用户目录"                            'rsync -a /home/user/a/ /home/user/b/'


# ============================================================
section "5. PreToolUse —— 非 Bash 工具不干预"
# ============================================================
NONBASH='{"session_id":"t","cwd":"/home/user","hook_event_name":"PreToolUse","tool_name":"Read","tool_input":{"file_path":"/etc/passwd"},"tool_use_id":"toolu_y"}'
run_hook "$NONBASH"; OUT="$HOOK_OUT"
[ "$RC" -eq 0 ] && [ -z "$OUT" ] && ok "Read 工具：exit 0 且无输出" || bad "Read 工具：应放行" "rc=$RC out=$OUT"

# 未知事件名不应报错
UNKNOWN='{"hook_event_name":"PostToolUse","tool_name":"Bash","tool_input":{"command":"rm -rf /"}}'
run_hook "$UNKNOWN"; OUT="$HOOK_OUT"
[ "$RC" -eq 0 ] && [ -z "$OUT" ] && ok "未订阅的事件：exit 0 且无输出" || bad "未订阅的事件" "rc=$RC out=$OUT"

# ============================================================
section "6. 只读性检查"
# ============================================================
# 用 python 做"命令位"扫描：只看每条语句的第一个词，避免把字符串里的
# "sudo chown root:root /" 之类的提示文本误判成真实写操作。
SUSPECT="$(python3 - "$HOOK" <<'PY'
import re, sys
src = open(sys.argv[1], encoding="utf-8").read()
writes = {"tee","mkdir","touch","rm","rmdir","chown","chgrp","chmod","sed","mv","cp",
          "truncate","dd","mkfs","wipefs","install","ln","shred","fallocate"}
bad = []
for no, line in enumerate(src.splitlines(), 1):
    code = line.split("#", 1)[0] if not line.lstrip().startswith("#") else ""
    if not code.strip():
        continue
    # 先去掉引号内的内容，避免把 grep 模式里的 chown|chmod 当成命令
    code = re.sub(r"'[^']*'", "''", code)
    code = re.sub(r'"[^"]*"', '""', code)
    for seg in re.split(r"\|\||&&|[;|&(){}\n]", code):
        words = seg.split()
        if not words:
            continue
        i = 1 if words[0] == "sudo" else 0
        if i < len(words) and words[i] in writes:
            # sed 只有 -i 才是写；systemctl 已从写入集合移出，单独判断
            if words[i] == "sed" and not any(w.startswith("-i") or w == "--in-place" for w in words[i+1:]):
                continue
            bad.append(f"{no}:{words[i]}")
        if "systemctl" in words:
            idx = words.index("systemctl")
            rest = words[idx+1:]
            if any(w in {"start","stop","restart","enable","disable","mask","unmask","reload"} for w in rest):
                bad.append(f"{no}:systemctl {rest[0] if rest else ''}")
for b in bad[:5]:
    print(b)
PY
)"
if [ -n "$SUSPECT" ]; then
  bad "脚本中没有写操作" "疑似包含写操作，请人工复核：$SUSPECT"
else
  ok "脚本中没有写操作（命令位扫描：无 rm/chown/chmod/sed -i/dd/mkfs/tee/mkdir 等）"
fi

# ============================================================
printf '\n\033[1m结果：%d 通过，%d 失败\033[0m\n' "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then
  printf '失败项：\n'
  for n in "${FAILED_NAMES[@]}"; do printf '  - %s\n' "$n"; done
  exit 1
fi
exit 0
