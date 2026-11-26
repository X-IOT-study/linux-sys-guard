# linux-sys-guard

[![tests](https://github.com/X-IOT-study/linux-sys-guard/actions/workflows/tests.yml/badge.svg)](https://github.com/X-IOT-study/linux-sys-guard/actions/workflows/tests.yml)
[![license: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[English](README.en.md)

一组**只做一件事、可以放心反复跑**的 Linux 系统维护小工具：防止 DNS 泄漏、
只读系统体检、zswap 管理、Claude Code 会话健康检查与危险命令拦截。

全部是纯 Bash + 标准 systemd 工具，**不依赖发行版特有的包管理器**：
Debian/Ubuntu、Fedora、Arch、openSUSE、Alpine 都会自动识别当前环境，
认不出来就明说「未识别」，不会假装自己是 apt 系统。

```
bin/
  dns-noleak.sh          让 systemd-resolved 只用加密的全局 DNS（DoT），不再泄漏给路由器/运营商
  sysaudit.sh            只读系统健康审计采集器（系统/硬件/存储/服务/网络 五节）
  zswapctl.sh            启用 / 关闭 / 体检 zswap（压缩 swap 缓存），可开机自启
  claude-health-hook.sh  Claude Code hook：会话启动健康检查 + 危险命令拦截
tests/
  test-dns-noleak.sh
  test-claude-health-hook.sh
docs/
  dns-noleak.md  sysaudit.md  zswapctl.md  claude-health-hook.md  compatibility.md
```

## 为什么会有这个仓库

配好 DNS-over-TLS 之后，很多人以为 DNS 就加密了。实际上：

```console
$ resolvectl status
Global
         Protocols: -LLMNR -mDNS +DNSOverTLS DNSSEC=no/unsupported
       DNS Servers: 1.1.1.1#cloudflare-dns.com 9.9.9.9#dns.quad9.net

$ resolvectl dns
Link 2 (enp2s0): 192.168.0.1      ← 路由器，明文
Link 3 (wlo1):   192.168.0.1      ← 路由器，明文
```

`systemd-resolved` 会把全局 DNS 和 **DHCP 下发的 per-link DNS 并行使用**
（resolved.conf(5) 原文：*"in parallel to suitable per-link DNS servers"*）。
更麻烦的是 per-link 查询会绑定源地址（`from 192.168.0.x`），从而**绕开**
TUN 的策略路由 —— 明文 DNS 直接到达路由器，运营商看得一清二楚。

而 per-link DNS **每换一个网络就重新出现一次**，所以「跑一次脚本清一次」必然失效。
这就是 `dns-noleak.sh` 存在的理由：把「清掉」做成常驻机制，而不是一次性的命令。

## 快速开始

```bash
git clone https://github.com/X-IOT-study/linux-sys-guard.git
cd linux-sys-guard
chmod +x bin/*.sh tests/*.sh
```

### 1. 不再泄漏 DNS（推荐先跑）

```bash
./bin/dns-noleak.sh --check      # 先体检，不需要 root
sudo ./bin/dns-noleak.sh          # 安装（幂等，换网络 / 重启后仍然生效）
sudo ./bin/dns-noleak.sh --revert # 全部还原
```

它解决的是这个具体问题：`systemd-resolved` 会把 DHCP 下发的 **per-link DNS**
（通常是路由器）与全局 DNS **并行**使用，而 per-link 查询会绑定源地址，
从而绕开 TUN / 策略路由 —— 于是 DNS 明文直连路由器，运营商看得一清二楚。
只在某个时刻清一次没用，因为**每换一个网络，per-link DNS 就又出现**。

安装后它会：
1. 写全局 `DNS-over-TLS` 配置（与连哪个网络无关）；
2. NetworkManager 环境 → 连接级 `ignore-auto-dns` + dispatcher 钩子；
   systemd-networkd 环境 → `.network` 的 `UseDNS=no` drop-in + networkd-dispatcher 钩子；
   都不认识 → 30 秒一次的 systemd timer 兜底（能力有限，会提示）；
3. 备份改动前的连接配置到 `/var/backups/dns-noleak-<时间戳>/`，随时可回滚。

默认解析器：Cloudflare `1.1.1.1`、Quad9 `9.9.9.9`、阿里 `223.5.5.5`
（阿里作为国内直连兜底，关掉代理也能解析）。可覆盖：

```bash
sudo DNS_SERVERS="1.1.1.1#cloudflare-dns.com 9.9.9.9#dns.quad9.net" ./bin/dns-noleak.sh
sudo EXTRA_DNS="1.0.0.1#cloudflare-dns.com" ./bin/dns-noleak.sh      # 追加
```

细节与原理见 [docs/dns-noleak.md](docs/dns-noleak.md)。

### 2. 只读系统体检

```bash
./bin/sysaudit.sh                          # 五节全跑，输出到脚本所在目录
./bin/sysaudit.sh --outdir ~/audit-out
./bin/sysaudit.sh --section network        # 只跑网络/代理/开发环境
./bin/sysaudit.sh --list                   # 列出分节
./bin/sysaudit.sh --timeout 60 --strict    # 单命令超时 60s，有采集失败则退出码 3
```

不调用 sudo、不写系统文件；每条命令都有超时；输出原子写入（先 `.tmp` 再 `mv`），
单条命令失败会标注 `[exit=N]` 而不是被管道吞掉。

### 3. zswap（慢速 swap 设备收益明显）

```bash
sudo ./bin/zswapctl.sh            # 启用（本机立即 + 开机自启）
./bin/zswapctl.sh verify          # 看压缩率 / 池占用，不需要 root
sudo ./bin/zswapctl.sh off        # 关闭并取消自启
sudo POOL_PERCENT=15 ./bin/zswapctl.sh   # 调大压缩池上限
```

### 4. Claude Code 健康检查 hook（可选）

```bash
bash tests/test-claude-health-hook.sh   # 先跑测试，确认行为
```

安装方式见 [docs/claude-health-hook.md](docs/claude-health-hook.md)。

## 兼容性

| 组件 | 要求 |
|---|---|
| shell | Bash 4+（dns-noleak / sysaudit / zswapctl） |
| dns-noleak | systemd 239+、systemd-resolved、`resolvectl`；NetworkManager 或 systemd-networkd |
| sysaudit | 任意 Linux；按存在的命令动态降级，缺失工具会给出对应发行版的安装提示 |
| zswapctl | 内核 `CONFIG_ZSWAP=y`（主流发行版默认开启） |
| claude-health-hook | Bash + `python3`（仅用于 JSON 编解码） |

不支持：非 systemd 系统上的 `dns-noleak.sh`（会明确报错退出，不做半套）。
更多说明见 [docs/compatibility.md](docs/compatibility.md)。

## 设计原则

- **幂等**：反复执行不叠加重叠配置。
- **可回滚**：改动前备份，`--revert` 一键还原。
- **只读优先**：能只读就别写；`sysaudit.sh` 全程只读。
- **失败要可见**：不用 `|| true` 掩盖问题，采集失败会写进报告。
- **不假设发行版**：包管理器、init、网络后端都先探测再使用。

## 测试

```bash
for t in tests/test-*.sh; do bash "$t" || exit 1; done
```

测试只跑不需要 root 的部分，不会改动系统。

## 许可

MIT，见 [LICENSE](LICENSE)。
