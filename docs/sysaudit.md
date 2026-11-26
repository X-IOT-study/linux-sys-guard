# sysaudit.sh

只读系统健康审计采集器。把一次排查需要的证据**一次性、完整地**落成文本文件，
方便事后对照、贴给他人、或跨时间比较。

```bash
./bin/sysaudit.sh                          # 五节全跑，输出到脚本所在目录
./bin/sysaudit.sh --outdir ~/audit-out
./bin/sysaudit.sh --section storage,services
./bin/sysaudit.sh --list
./bin/sysaudit.sh --timeout 60 --strict
```

## 设计要点

| 特性 | 说明 |
|---|---|
| 只读 | 不调用 sudo，不写系统文件。`--section` 之外没有副作用 |
| 原子输出 | 先写 `.tmp` 再 `mv`；中途崩溃不会留下半截报告，也不会覆盖上一次的完整报告 |
| 失败可见 | 命令非零退出会写 `[exit=N]`，不被管道吞掉；`--strict` 时整体退出码 3 |
| 分节隔离 | 每节在子 shell 里跑，某节出现未定义变量只损失这一节 |
| 超时保护 | 每条外部命令套 `timeout`（默认 30s），卡住的命令不会拖死整次采集 |
| 不假设发行版 | 包管理器、快照、重启标记都先探测再用 |

## 分节

| id | 内容 |
|---|---|
| `system` | 内核、发行版、启动时间、负载、内存、挂载、tmpfiles |
| `hardware` | CPU 频率/温度、GPU、风扇、电源、节流、intel_pstate / amd-pstate |
| `storage` | 磁盘布局、SMART、ext4 状态、inode、大目录、journal 占用 |
| `services` | 失败单元、日志错误、OOM、内核 taint、时间同步 |
| `network` | 接口/路由/DNS/代理/防火墙/连通性/开发环境 |

`--section network` 之类可以只跑需要的那一节。

## 退出码

| 码 | 含义 |
|---|---|
| 0 | 请求的分节都写出了文件（文件里可能仍有 `[exit=N]`，那是被采集对象的状态） |
| 1 | 有分节没写出文件 |
| 2 | 参数错误 / 输出目录不可写 / 缺少必需命令 |
| 3 | 指定了 `--strict`，且有采集命令失败 |

## 跨发行版处理

### 包管理器抽象

不硬编码 `apt`。`pkgmgr()` 按存在性探测，依次尝试
`apt-get` → `dnf` → `yum` → `pacman` → `zypper` → `apk`。

| 检查项 | 各发行版的实现 |
|---|---|
| 缺失工具的安装提示 | `pkg_hint smartmontools` → `apt install smartmontools` / `dnf install smartmontools` / `pacman -S smartmontools` / … |
| 依赖破损 | `apt-get -s check` / `dnf check` / `pacman -Dk` / `zypper verify` / `apk audit` |
| 被 hold 的包 | `apt-mark showhold` / `dnf versionlock list` / `pacman.conf` 的 `IgnorePkg` / `zypper locks` |
| 已装内核 | `dpkg -l 'linux-image-*'` / `rpm -qa 'kernel*'` / `pacman -Q \| grep linux` |
| 代理配置 | apt.conf.d / dnf.conf / pacman.conf / zypp.conf |

认不出包管理器时输出「(未识别包管理器，跳过)」，而不是假装是 apt 系统跑一堆
`command not found`。

### 网络探测目标

`http_probe()` 只挑跨发行版都存在的目标：`github.com`、`cloudflare.com/cdn-cgi/trace`、
`deb.debian.org`。不假设你用的是 Ubuntu 镜像。

超时、连不上、DNS 失败都被视为**网络状况的结论**（返回 0 并写明原因），
不是采集器故障 —— 否则离线机器上整节都会被标成失败。

### 重启标记

`/var/run/reboot-required` 是 Debian 系的做法；`needs-restarting -r` 是 dnf/yum 系。
`reboot_state()` 两个都查，都没有就明说「no reboot required marker」。

## 典型用法

**开机变慢 / 桌面发涩**

```bash
./bin/sysaudit.sh --section system,hardware,services
```

重点看：`services.txt` 里的失败单元与 OOM、`hardware.txt` 里的温度与节流、
`system.txt` 里的启动耗时。

**网络时好时坏**

```bash
./bin/sysaudit.sh --section network
```

重点看：`Link stats` 的丢包/错误计数、`Connectivity test (HTTP)` 的逐目标结论、
`Resolv.conf` 与 `Resolved status` 是否一致。

**磁盘疑似有问题**

```bash
sudo ./bin/sysaudit.sh --section storage
```

SMART 需要 root；不带 sudo 时 Permission denied 是预期现象，报告里也会注明。

## 与 dns-noleak 配合

```bash
./bin/dns-noleak.sh --check          # 专看 DNS 泄漏
./bin/sysaudit.sh --section network  # 看整体网络栈
```

两者视角不同：前者判断「DNS 会不会走本地网络」，后者判断「网络栈本身有没有毛病」。
