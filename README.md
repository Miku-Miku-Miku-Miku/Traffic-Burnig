# Traffic-Burnig

用 [Ookla 官方 Speedtest CLI](https://www.speedtest.net/apps/cli) 消耗本机闲置流量。可以限定燃烧时段、周期流量，以及上行和下行的最大速度。

官方客户端没有自带限速。脚本会在内核支持时用 `tc tbf` 做整形；否则用 nftables 限制测速进程的数据包。只要设置了最大速度，限速失败就会停止，不会退回成不限速燃烧。

## 定时和定量

这对应仓库 issue 里的需求：按时间段烧，并且烧到指定流量就停。

| 需求 | 配置 |
| --- | --- |
| 每天只在固定时段烧 | `SCHEDULE="01:00-07:00"`，跨夜写成 `22:00-02:00` |
| 这次最多烧两小时 | `DURATION="2h"` |
| 每天最多 20 GB | `QUOTA="20GB"`、`QUOTA_PERIOD="daily"` |
| 本月最多 200 GB | `QUOTA="200GB"`、`QUOTA_PERIOD="monthly"` |
| 下行不超过 30 Mbps，上行不超过 10 Mbps | `MAX_DOWNLOAD_MBPS="30"`、`MAX_UPLOAD_MBPS="10"` |

配额按运营商习惯的十进制计算，`1 GB = 1000 MB`。需要 1024 进制时写成 `GiB`。

官方测速一轮大约十几秒，配额会在这一轮结束后结算，所以实际用量可能略超过设定值。

## 安装

需要 root、`curl` 和 `python3`。脚本会补齐 `iproute2`、`nftables`、`iptables`。

```bash
curl -fsSL https://raw.githubusercontent.com/Miku-Miku-Miku-Miku/Traffic-Burnig/main/traffic-burning.sh -o /tmp/traffic-burning.sh
sudo bash /tmp/traffic-burning.sh install
```

直接把管道交给 bash 也可以。这种情况下安装步骤会再下载一次主分支脚本：

```bash
sudo bash <(curl -Ls https://raw.githubusercontent.com/Miku-Miku-Miku-Miku/Traffic-Burnig/main/traffic-burning.sh) install
```

安装位置：

- 命令：`/usr/local/bin/traffic-burn`
- 官方客户端：`/usr/local/bin/speedtest`（Ookla 1.2.0，校验 SHA256）
- 旧的 Python `speedtest-cli` 会被改名为 `speedtest.legacy`，不再使用

## 配置并后台运行

```bash
sudo traffic-burn init-config \
  --quota 20GB \
  --quota-period daily \
  --schedule 01:00-07:00 \
  --max-download 30 \
  --max-upload 10 \
  --interval 10 \
  --force

sudo traffic-burn service install
sudo traffic-burn service start
sudo traffic-burn status
```

没有 systemd 时，用 screen 跑前台循环：

```bash
screen -S traffic-burn
sudo traffic-burn run --config /etc/traffic-burn.conf
# Ctrl-A 然后 D 脱离
```

停止：

```bash
sudo traffic-burn stop
```

## 交互菜单

直接运行脚本会进入菜单，不会一上来就烧流量：

```bash
bash /tmp/traffic-burning.sh
```

不限制时段、配额和速度、一直烧到手动停止：

```bash
sudo traffic-burn run
```

## 常用命令

```text
traffic-burn install
traffic-burn init-config [选项]
traffic-burn run [选项]
traffic-burn status
traffic-burn stop
traffic-burn servers
traffic-burn service install|start|stop|restart|status|uninstall
traffic-burn uninstall [--purge]
```

`run` 的选项会覆盖配置文件。

```text
--quota 20GB
--quota-period daily          # run、daily、monthly
--schedule 01:00-07:00,22:00-23:30
--duration 2h                 # 也支持 90m、1d、0
--max-download 30
--max-upload 10
--max-mbps 20                 # 上行和下行用同一个上限
--interval 10
--server-id 12345
--once                        # 只测一轮
--dry-run                     # 只打印计划
```

查看附近节点：

```bash
traffic-burn servers
```

## 限速怎么做

Ookla CLI 1.2.0 不能只测上行或只测下行，也不能指定速度，所以两轮之间都会同时产生上行和下行流量。

- 内核有 `tbf` 队列时：为测速进程单独建网络命名空间，用 `tc tbf` 分别限制下行和上行。
- 没有 `tbf` 时：把测速进程放进 cgroup，用 nftables 丢掉超过上限的大包。ACK 这类小包不计入上限，避免把另一方向一起卡死。
- 两种方式都只作用于测速进程，不改网卡上已经存在的队列规则。

设定了最大速度但没有 root，或者限速规则创建失败时，进程会退出。

## 说明

运行官方客户端即表示接受 Ookla 的许可协议、服务条款和隐私政策。测速结果会提交到 Speedtest.net。

请把间隔、时段、配额和速度设在自己的套餐范围内。公共测速节点不是给持续打满用的。

卸载：

```bash
sudo traffic-burn uninstall
# 连配置、状态和日志一起删
sudo traffic-burn uninstall --purge
```

## 开发

```bash
bash tests/test_traffic_burn.sh
```

## 许可

本仓库脚本使用 GNU GPL v3 或更高版本。Ookla Speedtest CLI 是 Ookla 的专有程序，安装时从 `install.speedtest.net` 下载，不随本仓库分发。
