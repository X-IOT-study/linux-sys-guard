# 宣传文案草稿

三份可直接粘贴的文案。发布前请自己过一遍事实：**不要在没验证过的机器上声称效果**。

---

## A. Reddit / Hacker News 风格（英文，r/linux、r/sysadmin、r/selfhosted、r/privacy）

**Title:** `systemd-resolved uses DHCP DNS in parallel with your DoT servers — here's a hook that fixes it for good`

**Body:**

> Found this while chasing why DNS-over-TLS wasn't actually stopping lookups from
> reaching my router.
>
> `resolved.conf(5)` says: *"DNS requests are sent to one of the listed DNS servers
> in parallel to suitable per-link DNS servers."* So a global `DNS=1.1.1.1#cloudflare-dns.com`
> doesn't stop the DHCP-provided per-link server from being used too. And because
> per-link queries bind to the interface source address, they bypass TUN policy
> routing — plaintext DNS straight to the ISP.
>
> Clearing it once doesn't work either: it comes back on every network change.
>
> So I wrote a small installer that handles the three common cases:
>
> - NetworkManager → per-connection `ignore-auto-dns` + a dispatcher hook
> - systemd-networkd → `UseDNS=no` drop-in + networkd-dispatcher hook
> - unknown backend → 30s systemd timer (with a warning that it's best-effort)
>
> Idempotent, backs up to `/var/backups/` before touching anything, `--revert` puts
> it all back. Verified on Debian/Ubuntu/Fedora/Arch/openSUSE.
>
> Repo also has a read-only system audit script and a zswap helper — all
> distro-agnostic, no `apt` assumptions.
>
> https://github.com/X-IOT-study/linux-sys-guard
>
> Happy to hear where this breaks. Especially interested in systemd-networkd setups
> and distros I haven't tested.

**发布注意**

- r/linux 有严格的 self-promotion 规则：先在评论里帮别人解决问题，再贴链接。
- r/sysadmin 对「我写了个脚本」较冷淡，标题里放**具体现象**比放「我的项目」有效。
- 不要发到多个 sub 同一天，容易被判 spam。

---

## B. 中文（V2EX / 少数派 / 知乎 / 酷安）

**标题：** `配了 DNS-over-TLS 仍然泄漏？systemd-resolved 的 per-link DNS 坑`

**正文：**

> 记录一个排查了很久的坑。
>
> 以为在 `/etc/systemd/resolved.conf` 里写好 `DNS=1.1.1.1#cloudflare-dns.com` 加上
> `DNSOverTLS=yes` 就完事了。结果抓包发现路由器仍然收到明文 DNS 查询。
>
> 原因在 `resolved.conf(5)` 的一句话：
>
> > DNS requests are sent to one of the listed DNS servers in parallel to suitable
> > per-link DNS servers.
>
> 也就是**全局 DNS 和 DHCP 下发的 per-link DNS 是并行使用的**，后者通常就是路由器。
> 更糟的是 per-link 查询会绑定网卡源地址，绕开 TUN 的策略路由，明文直接出网。
>
> 而且这个 per-link DNS **每换一次网络就重新出现**，所以「写个脚本清一次」根本不管用——
> 换个 Wi-Fi 就白干。
>
> 后来写了个安装脚本，按网络后端分三种情况处理：
>
> - NetworkManager：连接级 `ignore-auto-dns` + dispatcher 钩子
> - systemd-networkd：`UseDNS=no` drop-in + networkd-dispatcher 钩子
> - 其它：30 秒定时兜底（会明确提示能力有限）
>
> 装一次，换网络、重启都还在。改之前会备份，`--revert` 能全部还原。
>
> 仓库里还有只读系统体检、zswap 管理，都是不假设发行版的纯 bash：
> https://github.com/X-IOT-study/linux-sys-guard
>
> 踩过的坑写在 docs 里，包括 `grep -q` + `pipefail` 导致 DoT 探测误判那个——
> 我第一版就是这么静默降级的，测了很久才发现。

**发布注意**

- V2EX 的「分享创造」节点最合适，标题里带「坑」比带项目名点击率高。
- 少数派偏好有完整叙述的长文，可以配截图（`resolvectl status` 前后对比）。
- 不要一稿多发到同一平台的不同节点。

---

## C. 一句话版本（GitHub / 微博 / X / 技术群）

> systemd-resolved 会把 DHCP 下发的 per-link DNS 和你的 DoT 服务器**并行**使用，
> 所以只配 `DNSOverTLS=yes` 并不能阻止明文查询发给路由器；而 per-link DNS 每换网络
> 就回来一次。写了个脚本按 NM / networkd / timer 三种后端把它永久清掉：
> https://github.com/X-IOT-study/linux-sys-guard

---

## 发之前值得做的

- [ ] 在一台**干净**的机器（虚拟机最方便）上从零跑一遍 `--check` → 安装 → `--revert`，
      确认没有依赖你自己机器的隐含前提。
- [ ] 至少在一台 systemd-networkd 的机器上验证过（当前只在 NetworkManager 上实测）。
- [ ] 截图 `resolvectl dns` 泄漏前后的对比，比任何文字都直观。
- [ ] 确认仓库里没有任何机器特定信息（用户名、硬盘型号、内网地址）。

## 不适合的宣传渠道

- 不要买 star、不要互 star 群 —— 一旦被发现，仓库的可信度就没了。
- 不要在无关的技术群里刷链接。
- 不要在 issue 里给自己仓库打广告。
