# linux-sys-guard

[![tests](https://github.com/X-IOT-study/linux-sys-guard/actions/workflows/tests.yml/badge.svg)](https://github.com/X-IOT-study/linux-sys-guard/actions/workflows/tests.yml)
[![license: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

Small Linux maintenance tools that each **do one thing and are safe to re-run**:
DNS leak prevention, read-only system audit, zswap control, and a Claude Code
session health-check hook.

Pure Bash + standard systemd tooling. **No distro assumptions** — Debian/Ubuntu,
Fedora, Arch, openSUSE and Alpine are detected at runtime; if it can't tell, it
says so instead of running a pile of `command not found`.

> [中文说明](README.md)

```
bin/
  dns-noleak.sh          make systemd-resolved use only encrypted global DNS (DoT)
  sysaudit.sh            read-only health audit (system/hardware/storage/services/network)
  zswapctl.sh            enable / disable / inspect zswap, optional boot-time unit
  claude-health-hook.sh  Claude Code hook: session health check + dangerous command guard
tests/
  test-dns-noleak.sh
  test-claude-health-hook.sh
docs/
  dns-noleak.md  sysaudit.md  zswapctl.md  claude-health-hook.md  compatibility.md
```

## Why this exists

After enabling DNS-over-TLS, most people assume DNS is encrypted. It usually isn't:

```console
$ resolvectl status
Global
         Protocols: -LLMNR -mDNS +DNSOverTLS DNSSEC=no/unsupported
       DNS Servers: 1.1.1.1#cloudflare-dns.com 9.9.9.9#dns.quad9.net

$ resolvectl dns
Link 2 (enp2s0): 192.168.0.1      ← your router, in plaintext
Link 3 (wlo1):   192.168.0.1      ← your router, in plaintext
```

`systemd-resolved` uses global DNS **in parallel to** the per-link DNS it got from
DHCP (resolved.conf(5): *"DNS requests are sent to one of the listed DNS servers in
parallel to suitable per-link DNS servers"*). Worse, per-link queries bind to the
interface source address, which **bypasses** policy routing for a TUN device — so
plaintext DNS goes straight to the router and your ISP sees every lookup.

And per-link DNS **comes back on every network change**, so clearing it once never
holds. That's the whole reason `dns-noleak.sh` exists: make the clearing persistent
instead of a one-shot command.

## Quick start

```bash
git clone https://github.com/X-IOT-study/linux-sys-guard.git
cd linux-sys-guard
chmod +x bin/*.sh tests/*.sh
```

### 1. Stop the DNS leak

```bash
./bin/dns-noleak.sh --check      # inspect first, no root needed
sudo ./bin/dns-noleak.sh          # install (idempotent, survives reboot & network changes)
sudo ./bin/dns-noleak.sh --revert # undo everything
```

Three layers:

1. Global DoT config in `/etc/systemd/resolved.conf.d/` — independent of which
   network you're on.
2. Per-link DNS never appears:
   - **NetworkManager** → per-connection `ignore-auto-dns` + a dispatcher hook
   - **systemd-networkd** → `UseDNS=no` drop-in + a networkd-dispatcher hook
   - **anything else** → 30-second systemd timer fallback (with a clear warning)
3. Pre-change connection settings backed up to `/var/backups/dns-noleak-<ts>/`.

Default resolvers: Cloudflare `1.1.1.1`, Quad9 `9.9.9.9`.

> Do not add a mainland resolver (e.g. Alibaba `223.5.5.5`) to this list.
> systemd-resolved picks servers **by response speed**, not list order; the
> mainland resolver always wins and returns forged answers for blocked domains.
> If a fake-ip proxy (Clash / mihomo) runs on the machine, hand system DNS to it
> instead (`DNS=127.0.0.1:1053` + `DNSOverTLS=no`) — this script does not cover
> that setup.

Override:

```bash
sudo DNS_SERVERS="1.1.1.1#cloudflare-dns.com 9.9.9.9#dns.quad9.net" ./bin/dns-noleak.sh
sudo EXTRA_DNS="1.0.0.1#cloudflare-dns.com" ./bin/dns-noleak.sh
```

Details: [docs/dns-noleak.md](docs/dns-noleak.md).

### 2. Read-only system audit

```bash
./bin/sysaudit.sh                          # all five sections
./bin/sysaudit.sh --outdir ~/audit-out
./bin/sysaudit.sh --section network
./bin/sysaudit.sh --list
./bin/sysaudit.sh --timeout 60 --strict    # exit 3 if any probe failed
```

Never calls sudo, never writes system files. Every command has a timeout. Output is
published atomically (`.tmp` + `mv`), and failed probes are marked `[exit=N]`
instead of being swallowed by a pipe.

### 3. zswap

```bash
sudo ./bin/zswapctl.sh              # enable now + at boot
./bin/zswapctl.sh verify            # compression ratio and pool usage, no root
sudo ./bin/zswapctl.sh off
sudo POOL_PERCENT=15 ./bin/zswapctl.sh
```

### 4. Claude Code health hook (optional)

```bash
bash tests/test-claude-health-hook.sh
```

Install instructions: [docs/claude-health-hook.md](docs/claude-health-hook.md).

## Compatibility

| Component | Requires |
|---|---|
| shell | Bash 4+ |
| dns-noleak | systemd 239+, systemd-resolved, `resolvectl`; NetworkManager or systemd-networkd |
| sysaudit | any Linux; degrades gracefully and gives distro-appropriate install hints |
| zswapctl | kernel `CONFIG_ZSWAP=y` (default on mainstream distros) |
| claude-health-hook | Bash + `python3` (JSON encoding only) |

Not supported: `dns-noleak.sh` on non-systemd systems — it exits with a clear error
rather than installing half a configuration. See [docs/compatibility.md](docs/compatibility.md).

## Design principles

- **Idempotent** — re-running never stacks duplicate config.
- **Reversible** — back up before touching anything; `--revert` restores.
- **Read-only first** — write only when there's no alternative.
- **Failures stay visible** — no `|| true` hiding real problems.
- **No distro assumptions** — probe the package manager, init and network backend.

## Tests

```bash
for t in tests/test-*.sh; do bash "$t" || exit 1; done
```

63 assertions, none require root, none modify the system.

## License

MIT — see [LICENSE](LICENSE).
