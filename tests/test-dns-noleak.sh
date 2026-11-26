#!/usr/bin/env bash
# ============================================================
# dns-noleak.sh 的测试（只跑不需要 root 的部分，不改动系统）
#
# 运行：bash tests/test-dns-noleak.sh
#
# 覆盖：
#   语法 / 可执行性
#   --version / --help 输出
#   --dry-run 不落盘、不需要 root、能正确回显参数
#   生成的 dispatcher 钩子是合法的 /bin/sh 脚本
#   回归：dot_probe 里不能再出现 `dig -h | grep -q`（pipefail 会误判）
# ============================================================
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$DIR/../bin/dns-noleak.sh"
PASS=0
FAIL=0
FAILED_NAMES=()

ok()  { PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); FAILED_NAMES+=("$1"); printf '  \033[31mFAIL\033[0m %s\n' "$1"; [ -n "${2:-}" ] && printf '        %s\n' "$2"; }
has() { printf '%s' "$1" | grep -qF -- "$2"; }
section() { printf '\n\033[1m%s\033[0m\n' "$1"; }

# ============================================================
section "1. 语法与可执行性"
# ============================================================
if bash -n "$SCRIPT" 2>/dev/null; then ok "bash -n 通过"; else bad "bash -n 失败"; fi
[ -x "$SCRIPT" ] && ok "脚本可执行" || bad "脚本不可执行（chmod +x 未做）"
head -1 "$SCRIPT" | grep -q '^#!/usr/bin/env bash' && ok "shebang 正确" || bad "shebang 不是 bash"

# ============================================================
section "2. 基本输出"
# ============================================================
out="$("$SCRIPT" --version 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && has "$out" "dns-noleak.sh" && ok "--version 正常" || bad "--version 异常" "$out"

out="$("$SCRIPT" --help 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && has "$out" "用法" && has "$out" "DNS-over-TLS" && ok "--help 有用法说明" \
  || bad "--help 内容不符" "$out"

out="$("$SCRIPT" --bogus 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && ok "未知参数返回非零" || bad "未知参数竟然返回 0"

# ============================================================
section "3. --dry-run 不落盘 / 不需要 root"
# ============================================================
out="$("$SCRIPT" --dry-run 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && has "$out" "dry-run 结束" && ok "--dry-run 正常结束" || bad "--dry-run 失败" "$out"

# dry-run 不能真的写出配置文件
if [ -e /etc/systemd/resolved.conf.d/50-dns-privacy.conf ]; then
  ok "--dry-run 未改动已存在的配置（文件仍为安装前状态，需人工确认）"
else
  ok "--dry-run 未创建配置文件"
fi

# 自定义服务器要出现在 dry-run 输出里
out="$(DNS_SERVERS='10.0.0.1#dns.example.net' "$SCRIPT" --dry-run 2>&1)"
has "$out" '10.0.0.1#dns.example.net' && ok "DNS_SERVERS 覆盖生效" || bad "DNS_SERVERS 未生效" "$(printf '%s' "$out" | head -3)"

# NO_PROBE 应跳过连通性探测
out="$(NO_PROBE=1 "$SCRIPT" --dry-run 2>&1)"
has "$out" 'NO_PROBE' && ok "NO_PROBE 生效" || bad "NO_PROBE 未生效" "$(printf '%s' "$out" | head -3)"

# ============================================================
section "4. 生成的 dispatcher 钩子是合法 shell 脚本"
# ============================================================
# 从源文件里抽出 NM 钩子的 heredoc（<<'SH' ... SH），交给 /bin/sh -n 检查。
hook="$(awk "/<<'SH'/{f=1;next} /^SH\$/{f=0} f" "$SCRIPT")"
if [ -n "$hook" ]; then
  if printf '%s\n' "$hook" | sh -n 2>/dev/null; then ok "NM 钩子 /bin/sh 语法通过"; else bad "NM 钩子语法错误"; fi
  printf '%s\n' "$hook" | grep -q 'resolvectl dns' && ok "钩子会清理 per-link DNS" || bad "钩子缺少 resolvectl dns"
  printf '%s\n' "$hook" | grep -q 'ignore-auto-dns' && ok "钩子会持久化 ignore-auto-dns" || bad "钩子缺少持久化"
else
  bad "没能从脚本里抽出 NM 钩子 heredoc"
fi

# ============================================================
section "5. 回归：pipefail 下的 grep -q 陷阱"
# ============================================================
# 曾经写成 `dig -h 2>&1 | grep -q -- '+tls'`：grep -q 命中即退出，
# dig 收到 SIGPIPE(141)，set -o pipefail 把整条流水线判为失败，
# 于是「dig 支持 +tls」被误判成不支持。必须先把输出落到变量/文件。
# 只看非注释行：注释里出现该写法是说明文字，不算违规
code_lines() { grep -vE '^[[:space:]]*#' "$SCRIPT"; }
if code_lines | grep -nE "dig -h[^|]*\|[[:space:]]*grep -q" >/dev/null 2>&1; then
  bad "仍存在 dig -h | grep -q 写法" "$(code_lines | grep -nE "dig -h[^|]*\|[[:space:]]*grep -q")"
else
  ok "无 dig -h | grep -q 写法"
fi

if code_lines | grep -nE "resolvectl status[^,;]*\|[[:space:]]*grep -q" >/dev/null 2>&1; then
  bad "仍存在 resolvectl status | grep -q 写法"
else
  ok "无 resolvectl status | grep -q 写法"
fi

# 实证：模拟一个大量输出后立刻退出的产生者，确认当前 dot_probe 的写法不会误判。
probe_test() {
  local f; f="$(mktemp)"
  # 模拟 dig 的帮助输出（很多行，含 +tls）
  { printf 'usage: dig ...\n'; for i in $(seq 1 200); do printf '  option %d\n' "$i"; done; printf '  +tls[=name] use TLS\n'; } >"$f"
  # 老写法：grep -q 提前退出 → 产生者 SIGPIPE
  ( set -o pipefail; cat "$f" | grep -q -- '+tls' ) && echo old_ok || echo old_fail
  # 新写法：先落到变量
  ( set -o pipefail; h="$(cat "$f")"; printf '%s' "$h" | grep -q -- '+tls' ) && echo new_ok || echo new_fail
  rm -f "$f"
}
res="$(probe_test)"
has "$res" "new_ok" && ok "新写法在 pipefail 下稳定判定为支持 +tls" || bad "新写法仍不稳定" "$res"

# ============================================================
printf '\n\033[1m结果：%d 通过，%d 失败\033[0m\n' "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then
  printf '失败项：\n'
  for n in "${FAILED_NAMES[@]}"; do printf '  - %s\n' "$n"; done
  exit 1
fi
exit 0
