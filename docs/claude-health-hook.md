# claude-health-hook.sh

Claude Code 的 hook 脚本，订阅两个事件：

| 事件 | 行为 |
|---|---|
| `SessionStart` | 会话开始时跑一次轻量健康检查（目标 < 3 秒），有问题才输出 `additionalContext`，正常时静默 |
| `PreToolUse` | Bash 工具执行前拦截已知的破坏性命令 |

**只读**：不修改系统状态，不创建文件。任何内部失败都退化为静默放行，不会阻断你干活。

## 先跑测试

```bash
bash tests/test-claude-health-hook.sh
```

47 项断言，覆盖语法、JSON 合法性、危险命令 deny、安全命令放行、坏输入健壮性、
以及「脚本里没有任何写操作」的静态扫描。

## 安装

1. 把脚本放到一个稳定位置（不要在会被清掉的临时目录）：

   ```bash
   mkdir -p ~/.claude/hooks
   cp bin/claude-health-hook.sh ~/.claude/hooks/
   chmod +x ~/.claude/hooks/claude-health-hook.sh
   ```

2. 在 `~/.claude/settings.json` 里注册：

   ```json
   {
     "hooks": {
       "SessionStart": [
         {
           "hooks": [
             { "type": "command", "command": "~/.claude/hooks/claude-health-hook.sh" }
           ]
         }
       ],
       "PreToolUse": [
         {
           "matcher": "Bash",
           "hooks": [
             { "type": "command", "command": "~/.claude/hooks/claude-health-hook.sh" }
           ]
         }
       ]
     }
   }
   ```

3. 新开一个会话验证。健康时不会有任何输出；有问题时你会看到一段
   「系统健康检查（只读）」的上下文。

## SessionStart 检查项

| # | 检查 | 判级 |
|---|---|---|
| 1 | `/` 属主不是 root | 高（`systemd-tmpfiles` 会拒绝清理 `/tmp`、`/run`、`/var/log`） |
| 2 | 失败的 systemd 单元 | 中（全部是低影响服务时降为提示） |
| 3 | `/` 或 `/home` 使用率 ≥ 85% | 中 |
| 4 | 本次启动 USB `error -71` 计数 | ≥100 中，≥20 提示 |
| 5 | CPU `Tctl` ≥ 90°C | 中 |
| 6 | `/var/run/reboot-required` 存在 | 提示 |
| 7 | Timeshift 快照数超过 `count_daily + 2` | 低 |

每条检查都套了 `timeout`（3–4 秒），任何一条卡住都不影响会话启动。

### 可调环境变量

| 变量 | 作用 |
|---|---|
| `HEALTH_LOW_IMPACT` | 视为「低影响」的服务名前缀，空格分隔，默认 `apport-autoreport` |
| `TIMESHIFT_SNAPSHOTS` | 快照目录，默认从 `timeshift.json` 推断，再退回 `/timeshift/snapshots` |

想加自己的低影响服务：

```json
{ "type": "command",
  "command": "HEALTH_LOW_IMPACT='apport-autoreport my-noise.service' ~/.claude/hooks/claude-health-hook.sh" }
```

## PreToolUse 拦截规则

只对 `Bash` 工具生效。命中任一条就返回 `permissionDecision: "deny"` 并给出原因：

| 规则 | 例子 |
|---|---|
| 递归 `chown`/`chmod` 作用于根目录 | `chown -R user /`、`chmod 755 -R /` |
| `rm -r` 作用于根目录 | `rm -rf /`、`rm -rf //`、`rm -rf /*/`、`--no-preserve-root` |
| `dd` 直接写裸盘/分区 | `dd of=/dev/nvme0n1`、`dd of=/dev/sda1`、`dd of=/dev/disk/by-id/...` |
| `mkfs` / `mke2fs` / `wipefs` 作用于块设备 | `mkfs.ext4 /dev/sdb1`、`wipefs -a /dev/sdc` |

**明确放行**的情况（都有测试覆盖）：

- `chown root:root /`（不加 `-R`，修 `/` 本身属主的正确做法）
- `rm -rf /tmp/build`、`rm -rf ~/.cache/uv`、`rm -rf /home/user/build/*`
- `dd if=/dev/zero of=~/test.img`（写普通文件）
- `mkfs.ext4 ~/test.img`（格式化镜像文件）
- `wipefs -n /dev/sdb`（`-n` 是 dry-run）
- `lsblk`、`blkid`、`smartctl -a`、`df`、`mount`（只读查询）
- 非 Bash 工具（`Read`、`Write` 等）完全不受影响

## 为什么用 deny 而不是 ask

`ask` 需要人在场；长时间无人值守的会话会卡住。`deny` 让模型立刻拿到明确原因
（「递归 chown/chmod 作用在根目录…如果只是修复 / 本身，去掉 -R」），
从而自己改写成正确命令 —— 这也是它拦截 `chown -R /` 却放行 `chown root:root /` 的原因。

## 实现细节

### 一次 python3 调用解析输入

用 NUL 分隔字段，避免命令里含换行/空格时被拆错：

```sh
FIELDS=()
while IFS= read -r -d '' _f; do FIELDS+=("$_f"); done < <(parse_input)
```

### JSON 输出

中文用 `json.dumps` 转义成 `\uXXXX`，保证任何 locale 下都是合法 JSON：

```sh
json_escape() { python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))' 2>/dev/null; }
```

### 块设备正则

```
/dev/(nvme[0-9]+n[0-9]+(p[0-9]+)?|sd[a-z][0-9]*|vd[a-z][0-9]*|mmcblk[0-9]+(p[0-9]+)?|...)
```

覆盖 NVMe、SATA/SCSI、virtio、eMMC/SD，以及 `/dev/disk/by-*`、`/dev/mapper/*` 这些
稳定路径写法 —— 用 UUID 路径绕过检查是常见疏漏。
