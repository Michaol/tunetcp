# TuneTCP

[![许可证: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](https://www.gnu.org/licenses/gpl-3.0) ![Badge](https://hitscounter.dev/api/hit?url=https%3A%2F%2Fgithub.com%2FMichaol%2Ftunetcp&label=&icon=github&color=%23198754&message=&style=flat&tz=Asia%2FShanghai)

一个为 Linux 服务器设计的智能、交互式 TCP/UDP 网络性能优化脚本。自动启用 BBR/BBRv2 拥塞控制和 FQ 包调度器，并根据实际环境科学配置 TCP/UDP 缓冲区，充分利用服务器带宽，改善网络传输效率。

## 主要特性

- **BBRv2 自动检测**: 内核 5.8+ 自动启用 BBRv2，否则回退到 BBRv1
- **智能检测**: 自动检测服务器内存；智能识别 SSH 客户端 IP 作为 RTT 测试目标
- **增强 RTT 检测**: 多目标 fallback (1.1.1.1 → 8.8.8.8 → 223.5.5.5)，返回抖动和丢包率
- **内存分层优化**: low/medium/high 三级内存配置，512MB 小机器也能安全运行
- **代理/VPN 优化**: TCP 重传、ECN、薄流优化、RPS/XPS、conntrack 等专项配置
- **双栈支持**: 同时优化 IPv4 和 IPv6 的 TCP/UDP（单栈和双栈服务器均适用）
- **动态调整**: 连接队列、缓冲区、UDP 内存上限根据内存和带宽自动调整
- **交互式体验**: 展示所有检测值，允许手动修改或确认
- **非交互模式**: 支持命令行参数，适合脚本化部署
- **自动冲突处理**: 扫描并处理现有冲突配置，通过备份解决配置覆盖问题
- **即时生效与持久化**: 配置即时生效并写入 `/etc/sysctl.d/`，重启后依然有效
- **安全优先**: 内核版本（4.9+）兼容性检查，`tcp_moderate_rcvbuf` 自动调节保护
- **全平台兼容**: 严格遵循 **POSIX** 标准，完美支持 Debian/Ubuntu/CentOS/Fedora/Alpine (BusyBox) 等
- **预览模式**: `--dry-run` 参数，无需修改系统即可预览生成的配置
- **调试模式**: `-d/--debug` 参数，详细记录执行流与决策逻辑

## 一键运行

以 root 用户身份登录 Linux 服务器，执行以下命令：

```bash
wget -qO tunetcp.sh https://raw.githubusercontent.com/Michaol/tunetcp/main/tunetcp.sh && chmod +x tunetcp.sh && ./tunetcp.sh
```

## 命令行参数

```text
用法: ./tunetcp.sh [选项]

选项:
  -m, --mem <GiB>     指定内存大小（默认自动检测）
  -b, --bw <Mbps>     指定出口带宽（默认 1000）
  -r, --rtt <ms>      指定网络延迟（默认自动检测）
  -y, --yes           跳过确认，直接应用
  --uninstall         卸载优化配置，恢复系统默认
  --dry-run           只预览配置，不实际写入系统
  -d, --debug         开启调试模式
  -h, --help          显示帮助信息
```

### 示例

```bash
# 交互模式（默认）
./tunetcp.sh

# 非交互模式，指定带宽和RTT
./tunetcp.sh -b 500 -r 50 -y

# 预览配置（不修改系统）
./tunetcp.sh --dry-run -b 1000 -r 100 -y

# 卸载配置
./tunetcp.sh --uninstall
```

## 工作流程

1. **环境检测**: 检查 root 权限，内核版本（BBR/BBRv2 支持），CPU 核心数，conntrack 模块
2. **内存分层**: 根据内存大小自动分为 low (<1GB) / medium (1-4GB) / high (≥4GB)
3. **RTT 检测**: 优先使用 SSH 客户端 IP，失败则依次尝试公共 DNS；同时检测抖动和丢包率
4. **参数确认**: 展示并允许修改检测值
5. **科学计算**: 基于 `min(2*BDP, X%RAM, YMB)` 策略确定最优缓冲区（X/Y 根据内存层级调整）
6. **清理冲突**: 备份并注释冲突配置
7. **应用配置**: 写入 `/etc/sysctl.d/999-net-bbr-fq.conf` 并执行
8. **附加优化**: 配置 RPS/XPS（多队列网卡）和 conntrack
9. **结果验证**: 打印生效的网络参数和优化状态

## 优化项一览

### 拥塞控制

| 参数 | 说明 |
|------|------|
| `tcp_congestion_control` | BBRv2 (内核 5.8+) 或 BBRv1 |
| `default_qdisc = fq` | FQ 包调度器 |

### TCP 缓冲区

| 参数 | 说明 |
|------|------|
| `tcp_rmem` / `tcp_wmem` | 基于 BDP 动态计算 max 值 |
| `rmem_max` / `wmem_max` | 上限 `min(2×BDP, X%RAM, YMB)` |
| | 低内存: X=2%, Y=16MB；其他: X=3%, Y=64MB |

### TCP 性能

| 参数 | 说明 |
|------|------|
| `tcp_fastopen = 7` | 客户端+服务端+无cookie TFO |
| `tcp_fastopen_connect = 1` | 客户端 TFO 连接 |
| `tcp_notsent_lowat = 131072` | Cloudflare 推荐，提升发送吞吐 |
| `tcp_moderate_rcvbuf = 1` | 缓冲区自动调节安全网 |
| `tcp_slow_start_after_idle = 0` | 禁用空闲后慢启动 |
| `tcp_mtu_probing = 1` | 路径 MTU 发现 |

### TCP 重传与连接管理 (代理/VPN 优化)

| 参数 | 说明 |
|------|------|
| `tcp_retries1 = 3` | 快速发现路径问题 |
| `tcp_retries2 = 8/10/12` | 根据丢包率动态调整 |
| `tcp_syn_retries = 2` | SYN 快速超时 |
| `tcp_synack_retries = 2` | SYN-ACK 快速超时 |
| `tcp_abort_on_overflow = 1` | 高负载时快速拒绝 |
| `tcp_max_tw_buckets` | 按内存层级动态计算 |

### ECN 与薄流优化

| 参数 | 说明 |
|------|------|
| `tcp_ecn = 1` | 启用显式拥塞通知 |
| `tcp_ecn_fallback = 1` | ECN 回退支持 |
| `tcp_thin_linear_timeouts = 1` | 薄流重传优化 |
| `tcp_thin_dupack = 1` | 薄流重复 ACK |

### 连接队列

| 参数 | 说明 |
|------|------|
| `somaxconn` | low: 4096 / medium: 32768 / high: 65535 |
| `netdev_max_backlog` | 根据带宽和内存层级动态调整 |
| `netdev_budget = 600` | 提升软中断处理效率 |

### UDP 优化 (QUIC/WireGuard 友好)

| 参数 | 说明 |
|------|------|
| `udp_rmem_min / udp_wmem_min` | 16384 |
| `udp_mem` | low: 1%/2%/3% / medium: 3%/4%/6% / high: 4%/5%/8% |

### 文件描述符与 VM 调优

| 参数 | low (<1GB) | medium/high |
|------|-----------|-------------|
| `fs.file-max` | 262144 | 2097152 |
| `vm.swappiness` | 30 | 10 |
| `vm.dirty_ratio` | 15 | 15 |
| `vm.dirty_background_ratio` | 5 | 5 |

### 多队列网卡 (RPS/XPS)

仅在 medium/high 内存且 CPU 核心数 > 网卡队列数时配置：
- RPS: 软件接收包分发到多核
- XPS: 发送队列 CPU 绑定
- RFS: 流表大小根据 CPU 核心数计算

### 连接跟踪 (Conntrack)

仅在模块可用时配置，按内存层级设置上限：

| 内存层级 | conntrack_max |
|---------|---------------|
| low | 131072 |
| medium | 524288 |
| high | 1048576 |

## 内存层级配置对比

| 参数 | low (<1GB) | medium (1-4GB) | high (≥4GB) |
|------|-----------|----------------|-------------|
| RAM 占用比例 | 2% | 3% | 3% |
| 缓冲区硬上限 | 16 MB | 64 MB | 64 MB |
| somaxconn | 4,096 | 32,768 | 65,535 |
| netdev_backlog | 按带宽/5 | 按带宽 | 按带宽 |
| udp_mem | 1%/2%/3% | 3%/4%/6% | 4%/5%/8% |
| tcp_max_tw_buckets | 32,768 | 131,072 | min(MEM_MB×10, 200K) |
| conntrack_max | 131,072 | 524,288 | 1,048,576 |
| fs.file-max | 262,144 | 2,097,152 | 2,097,152 |
| vm.swappiness | 30 | 10 | 10 |
| RPS/XPS | 不配置 | 按需配置 | 按需配置 |

## 卸载

运行以下命令恢复系统默认配置：

```bash
./tunetcp.sh --uninstall
```

或手动删除配置文件：

```bash
rm -f /etc/sysctl.d/999-net-bbr-fq.conf && sysctl --system
```

## 常见问题

### BBR 未生效

1. 检查内核版本（BBR 需要 4.9+，BBRv2 需要 5.8+）：`uname -r`
2. 检查 BBR 模块：`modprobe tcp_bbr && lsmod | grep bbr`
3. 检查可用拥塞控制算法：`cat /proc/sys/net/ipv4/tcp_available_congestion_control`
4. 部分云服务商的内核可能未编译 BBR 支持

### 配置未持久化

确保配置文件存在：`cat /etc/sysctl.d/999-net-bbr-fq.conf`

### 如何恢复原配置

脚本会自动备份冲突文件为 `*.bak.时间戳` 格式，可手动恢复。

### 512MB 小内存机器

脚本会自动检测内存并使用 low 层级配置：
- 缓冲区上限降低到 16MB
- 连接队列减小到 4096
- conntrack 上限为 131072
- 跳过 RPS/XPS 配置
- vm.swappiness 提高到 30（允许更多交换）

### 代理/VPN 服务器

脚本自动启用以下优化：
- TCP 重传参数优化（快速发现和恢复）
- ECN 显式拥塞通知
- 薄流优化（适合交互式连接）
- 更大的 UDP 缓冲区（QUIC/WireGuard 友好）
- RPS/XPS 多队列负载均衡（多 vCPU 时）
- conntrack 按内存配置（高并发连接）
