# dns-noleak.sh

让 `systemd-resolved` **只用加密的全局 DNS**，不再把查询发往本地路由器 / 运营商。

```bash
./bin/dns-noleak.sh --check      # 体检，不需要 root
sudo ./bin/dns-noleak.sh          # 安装（幂等）
sudo ./bin/dns-noleak.sh --dry-run
sudo ./bin/dns-noleak.sh --revert
```

## 要解决的问题

`systemd-resolved` 会**并行**使用两类上游服务器：

- 全局 `DNS=`（来自 `/etc/systemd/resolved.conf` 或 `resolved.conf.d/*.conf`）
- 每个网卡的 **per-link DNS**（来自 DHCP，通常是路由器）

resolved.conf(5) 原文：

> DNS requests are sent to one of the listed DNS servers in parallel to
> suitable per-link DNS servers.

也就是说，**光写全局 DoT 配置并不能阻止泄漏**。更糟的是，per-link 查询会绑定
源地址（`from 192.168.0.x`），从而**绕开** TUN 的策略路由，明文 DNS 直接到达路由器。

而 per-link DNS 是**每次换网络就重新出现一次**的，所以「跑一次脚本清一次」
必然失效 —— 这正是必须做成常驻机制的原因。

## 三层结构

### 第 1 层：全局 DoT 配置（与网络无关）

`/etc/systemd/resolved.conf.d/50-dns-privacy.conf`：

```ini
[Resolve]
DNS=1.1.1.1#cloudflare-dns.com 9.9.9.9#dns.quad9.net 223.5.5.5#dns.alidns.com
DNSOverTLS=yes
Domains=~.
FallbackDNS=
DNSSEC=no
```

- `地址#主机名` 是 DoT 的 SNI 语法，缺了它证书校验会失败。
- `DNSOverTLS=yes` 是**严格模式**：服务器不支持 TLS 就直接失败，不会退回明文。
- `FallbackDNS=` 置空，避免系统偷偷补上一组明文公共 DNS。
- `DNSSEC=no`：部分网络会拦掉 DNSSEC 记录导致解析失败，隐私收益不抵可用性损失。

### 第 2 层：per-link DNS 永远不出现

按网络后端分三种处理：

**NetworkManager**

1. 给所有已存在的 Wi-Fi / 有线连接打上 `ipv4.ignore-auto-dns yes ipv6.ignore-auto-dns yes`
   —— 下次连同一网络，NM 从一开始就不下发 DHCP DNS。
2. 装 dispatcher 钩子 `/etc/NetworkManager/dispatcher.d/90-dns-noleak`：
   在 `up` / `dhcp4-change` / `dhcp6-change` 时执行
   `resolvectl dns "$IFACE" ""` 清空运行时值，并把 `ignore-auto-dns` 写回该连接
   —— 这样**新遇到的网络**也会被永久修好。

钩子里的两个细节：

```sh
# resolvectl 处理不了非 ASCII / 含空格的接口名，跳过
case "$IFACE" in ""|*[!A-Za-z0-9_.-]*) exit 0 ;; esac

# 等 NM 通过 D-Bus 把 DNS 推完，避开时序竞争
sleep 0.3
```

**systemd-networkd**

1. 给每个 `.network` 文件加 drop-in `<name>.network.d/90-no-dhcp-dns.conf`：

   ```ini
   [Network]
   UseDNS=no
   ```

   注意 `UseDNS=` 只在 `[Network]` 段生效；`networkd.conf` 的 `[DHCPv4]` 段
   （systemd 249）**不支持** `UseDNS`，写在那里是无效的。

2. 装了 `networkd-dispatcher` 就装 `/etc/networkd-dispatcher/routable.d/90-dns-noleak`
   做事件驱动清理；没装则退化为第 3 层。

**未知网络管理器**

30 秒一次的 systemd timer 兜底：

```
/etc/systemd/system/dns-noleak-guard.timer     OnBootSec=20s, OnUnitActiveSec=30s
/etc/systemd/system/dns-noleak-guard.service   遍历 resolvectl dns 清空
```

这条路径能力有限（有最长 30 秒的泄漏窗口），安装时会明确提示。

### 第 3 层：备份与回滚

改动前把连接原值写进 `/var/backups/dns-noleak-<时间戳>/connections.txt`
（`<uuid> <v4> <v6>`），`--revert` 逐条写回。

## 可调环境变量

| 变量 | 作用 |
|---|---|
| `DNS_SERVERS="ip#sni ..."` | 完全覆盖解析器列表 |
| `EXTRA_DNS="ip#sni"` | 追加到默认列表 |
| `NO_PROBE=1` | 跳过 DoT 连通性预检（离线 / 受限网络） |
| `FORCE=1` | 全部探测不通也照样写入 |

## 关于 DoT 探测

`dot_probe()` 按可靠性从高到低尝试：

1. `dig +tls=<sni> @<ip>` —— 需要 dig 支持 `+tls`（BIND 9.18+）
2. `openssl s_client -connect ip:853 -servername sni -brief` —— 看是否完成握手
3. `/dev/tcp` 端口可达性 —— 只作参考，中间设备可能放行 TCP 却打断 TLS

### 一个真实的坑：`grep -q` + `pipefail`

最初的实现是：

```sh
if have dig && dig -h 2>&1 | grep -q -- '+tls'; then
```

在 `set -o pipefail` 下这段**必然判为失败**：`grep -q` 命中第一条就退出，
`dig` 收到 SIGPIPE 退出码 141，pipefail 让整条流水线返回非零。
结果是「dig 支持 +tls」被误判成「不支持」，静默降级到 openssl。

正确写法是先落变量再查：

```sh
dighelp="$(dig -h 2>&1 || true)"
if have dig && printf '%s' "$dighelp" | grep -q -- '+tls'; then
```

同样的坑也存在于 `resolvectl status | grep -q '+DNSOverTLS'`。`tests/test-dns-noleak.sh`
里有针对这两处的回归测试。

## 验证

```bash
./bin/dns-noleak.sh --check
```

正常输出应包含：

```
OK  没有 per-link DNS
  有  /etc/systemd/resolved.conf.d/50-dns-privacy.conf
  有  /etc/NetworkManager/dispatcher.d/90-dns-noleak
```

以及 `resolvectl status` 顶部出现 `+DNSOverTLS`。

## 常见问题

**关掉代理后完全不能上网？**

默认列表里已经放了阿里 `223.5.5.5`（国内直连可达）。如果你的网络连阿里也到不了，
用 `DNS_SERVERS=` 指定本地可达的 DoT 服务器，或加 `NO_PROBE=1 FORCE=1`。

**`/etc/resolv.conf` 里是 `127.0.0.53`，正常吗？**

正常。那是 resolved 的本地 stub，不是上游服务器。上游在 `resolvectl status` 里看。

**NM 的 `dns=none` 能替代 `ignore-auto-dns` 吗？**

不能。`none` 是 `symlink` 的**废弃别名**，只控制 `/etc/resolv.conf` 的写入方式，
不影响 NM 通过 D-Bus 把 DNS 推给 resolved 的行为。

**重启后还在吗？**

在。改动全在磁盘上（`resolved.conf.d`、`dispatcher.d`、连接 profile），
且 `systemd-resolved` 与 `NetworkManager` 默认 enabled。
