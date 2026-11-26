# zswapctl.sh

启用 / 关闭 / 体检 **zswap**（压缩 swap 缓存），可开机自启。

```bash
sudo ./bin/zswapctl.sh            # 启用（立即生效 + 开机自启）
./bin/zswapctl.sh verify          # 看压缩率与池占用（不需要 root）
sudo ./bin/zswapctl.sh off        # 关闭并取消自启
sudo POOL_PERCENT=15 ./bin/zswapctl.sh
```

## zswap 是什么

换出的页**先在内存里用 zstd 压缩存放**，只有压缩池满了才真正写盘。

对慢速 swap 设备收益最大：eMMC、SD 卡、DRAM-less SSD、机械硬盘。
典型效果是压缩比 3:1 ~ 4:1，意味着换出的内存里只有 1/4 真的碰到磁盘，
随机写少很多，切应用时的卡顿明显减轻。

前提：内核有 `CONFIG_ZSWAP=y`（主流发行版内核默认开启）。

```bash
ls /sys/module/zswap/parameters/    # 目录存在即支持
```

## 用法

### on（默认）

```bash
sudo ./bin/zswapctl.sh
```

做三件事：

1. 若 `enabled` 不是 `Y`，依次写 `compressor=zstd`、`zpool=zsmalloc`、
   `max_pool_percent=<POOL_PERCENT>`、`enabled=1`。
   **顺序不能反**：前三项必须在 `enabled=1` 之前写，否则返回 `EBUSY`。
2. 写 `/etc/systemd/system/zswap.service`（oneshot，`Before=swap.target`），
   让开机时在 swap 挂载前把 sysfs 配好。
3. 打印当前内存状况与推算出的池上限。

### off

```bash
sudo ./bin/zswapctl.sh off
```

停用并删除 unit，`enabled=0`。**不会**把已经在 swap 里的页搬回内存。

### verify

```bash
./bin/zswapctl.sh verify
```

```
压缩池占用         858.1 MB
累计经过 zswap    3051.3 MB
压缩率              3.56 : 1
池上限              1366 MB（MemTotal 的 10%）
```

- `Zswap` = 压缩池当前占用（kB）
- `Zswapped` = 累计有多少内存从 zswap 走过（kB）
- 两者之比就是压缩率

有 debugfs 且可读时还会打印 `/sys/kernel/debug/zswap/stats` 明细：

- `written_back_pages`：池满后被挤回磁盘的页数，越小越好
- `pool_limit_hit`：持续增长说明池上限不够，可以调大

## 池上限怎么定

`POOL_PERCENT`（默认 10）是占 `MemTotal` 的百分比。

压缩池本身占 RAM：池给太大反而会把可用内存吃光。经验值：

- 8 GB 内存：10%
- 16 GB 内存：10–15%
- 32 GB 以上：10% 通常足够（绝对量已经很大）

改上限必须**先关再改**，否则 `EBUSY`：

```bash
sudo sh -c 'echo 0 > /sys/module/zswap/parameters/enabled
            echo 15 > /sys/module/zswap/parameters/max_pool_percent
            echo 1 > /sys/module/zswap/parameters/enabled'
```

用本脚本重跑 `POOL_PERCENT=15 sudo ./bin/zswapctl.sh` 会顺带更新开机 unit。

## 重要限制

**只对之后新换出的页生效。** 已经躺在 swap 里的页不会迁移过来。

想让存量页也走 zswap，需要 `swapoff -a && swapon -a` —— 而 `swapoff` 要把整个
swap **读回内存**，空闲内存不够时会 OOM。脚本不会替你这么做。
如果确实需要，先确认 `MemAvailable` 大于 swap 已用量：

```bash
awk '/^SwapTotal:|^SwapFree:|^MemAvailable:/' /proc/meminfo
```

## 与 zram 的区别

| | zswap | zram |
|---|---|---|
| 本质 | 给**真实 swap 设备**加一层压缩缓存 | 用 RAM 造一个**块设备**当 swap |
| 需要 swap 分区/文件 | 需要 | 不需要 |
| 内存压力大时 | 溢出的页写盘 | 溢出的页丢失或 OOM |

已有 swap 分区的机器上，zswap 是更省心的选择。
