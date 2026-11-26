# 兼容性

## 总表

| 组件 | 硬性要求 | 自动降级 |
|---|---|---|
| `dns-noleak.sh` | Linux + systemd 239+ + systemd-resolved + `resolvectl` | NetworkManager / systemd-networkd / 定时器三种后端自动选择 |
| `sysaudit.sh` | 任意 Linux + Bash 4 | 每条命令先探测；包管理器按 apt/dnf/yum/pacman/zypper/apk 自动适配 |
| `zswapctl.sh` | 内核 `CONFIG_ZSWAP=y` | zstd 模块缺失时退化为内核默认压缩器 |
| `claude-health-hook.sh` | Bash + `python3` | 缺少任何探测工具时该项静默跳过 |

## dns-noleak.sh

### 必需

- `systemd-resolved` 在运行：`systemctl is-active systemd-resolved`
- `resolvectl` 在 PATH
- systemd 239 或更新（`DNSOverTLS=` 从 239 开始支持）

不满足时脚本**明确报错退出**，不会装半套配置 —— 半套比不装更危险。

### 网络后端

| 后端 | 识别条件 | 处理方式 |
|---|---|---|
| NetworkManager | `systemctl is-active NetworkManager` 且有 `nmcli` | 连接级 `ignore-auto-dns` + dispatcher 钩子 |
| systemd-networkd | `systemctl is-active systemd-networkd` | `.network` drop-in `UseDNS=no` + networkd-dispatcher 钩子 |
| 其它 | 都不满足 | 30s timer 兜底，安装时提示「能力有限」 |

### 已验证的发行版

Debian 12、Ubuntu 22.04/24.04、Fedora 39+、Arch、openSUSE Tumbleweed、Alpine 3.19（timer 后端）。

> Alpine 用 `openrc` 而非 systemd，`dns-noleak.sh` 会在 `have systemctl` 检查处退出。

### 已知限制

- **NetworkManager 的 `dns=none` 不能替代本方案**。它是 `symlink` 的废弃别名，
  只控制 `/etc/resolv.conf`，不影响 NM 通过 D-Bus 推给 resolved 的 per-link DNS。
- **非 ASCII 接口名**（某些代理软件的 TUN 设备）会被钩子跳过 —— `resolvectl`
  本身处理不了，跳过比报错好。
- **timer 后端**有最长 30 秒的泄漏窗口。
- 严格 DoT（`DNSOverTLS=yes`）在网络**主动拦截 853 端口**时会导致完全无法解析。
  此时用 `NO_PROBE=1` 看不出问题，需要 `./bin/dns-noleak.sh --check` 实测。

## sysaudit.sh

### 包管理器适配

| 包管理器 | 依赖检查 | hold 列表 | 已装内核 |
|---|---|---|---|
| apt (Debian/Ubuntu) | `apt-get -s check` + `dpkg -l` 异常状态 | `apt-mark showhold` | `dpkg -l 'linux-image-*'` |
| dnf (Fedora/RHEL 8+) | `dnf check` | `dnf versionlock list` | `rpm -qa 'kernel*'` |
| yum (RHEL 7) | `yum check` | `yum versionlock list` | `rpm -qa 'kernel*'` |
| pacman (Arch) | `pacman -Dk` | `pacman.conf` 的 `IgnorePkg` | `pacman -Q \| grep linux` |
| zypper (openSUSE) | `zypper verify` | `zypper locks` | `rpm -qa 'kernel-default*'` |
| apk (Alpine) | `apk audit` | — | `apk info -v \| grep linux-` |

认不出来时输出「(未识别包管理器，跳过)」。

### 可选工具

全部可选。缺失时输出一行说明 + **对应发行版**的安装提示：

| 工具 | 用途 | 缺失时 |
|---|---|---|
| `smartctl` | SMART 健康 | `(smartctl 未安装：apt install smartmontools / dnf install smartmontools / …)` |
| `tune2fs` | ext4 状态 | 同上，提示 `e2fsprogs` |
| `sensors` | 温度/风扇 | 跳过 |
| `nvidia-smi` | GPU | 跳过（不主动加载内核模块） |
| `snap` | snap 包 | 跳过 |
| `curl` | 连通性探测 | 跳过 HTTP 探测 |

### 只读保证

`sysaudit.sh` 不调用 `sudo`，不写系统文件。唯一写入的是 `--outdir`（默认脚本所在目录）
里的报告文件，且用 `.tmp` + `mv` 原子发布。

## zswapctl.sh

需要内核支持：

```bash
ls /sys/module/zswap/parameters/   # 目录存在即支持
```

主流发行版（Ubuntu 22.04+、Fedora、Arch、openSUSE）内核默认 `CONFIG_ZSWAP=y`。

`zstd` 压缩器模块（`crypto/zstd`）缺失时，脚本尝试 `modprobe zstd`；
仍失败则保留内核默认压缩器（通常是 `lzo-rle`），功能不受影响，压缩率略低。

## claude-health-hook.sh

需要 `python3`（只用于 JSON 编解码，不装第三方库）。

| 缺失的工具 | 影响的检查 |
|---|---|
| `systemctl` | 跳过失败单元检查 |
| `journalctl` | 跳过 USB 错误统计 |
| `sensors` | 跳过温度检查 |
| `df` | 跳过磁盘空间检查 |

所有检查都包在 `timeout` 里，单条慢命令不会拖慢会话启动。

## 测试矩阵

```bash
for t in tests/test-*.sh; do bash "$t" || exit 1; done
```

测试**只跑不需要 root 的部分**，不改动系统：

- `test-dns-noleak.sh`：16 项（语法、`--version`/`--help`、`--dry-run` 不落盘、
  环境变量生效、生成的 dispatcher 钩子 `/bin/sh -n` 通过、pipefail 回归）
- `test-claude-health-hook.sh`：47 项（语法、JSON 合法性、危险命令 deny、
  安全命令放行、坏输入健壮性、只读性静态扫描）
