# TuneTCP

[![许可证: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](https://www.gnu.org/licenses/gpl-3.0) ![Badge](https://hitscounter.dev/api/hit?url=https%3A%2F%2Fgithub.com%2FMichaol%2Ftunetcp&label=&icon=github&color=%23198754&message=&style=flat&tz=Asia%2FShanghai)

一个为 Linux 服务器设计的智能、交互式 TCP/UDP 网络性能优化脚本。自动启用 BBRv1 拥塞控制和 FQ 包调度器，并根据实际环境科学配置 TCP/UDP 缓冲区，充分利用服务器带宽，改善网络传输效率。

## 主要特性

- **智能检测**: 自动检测服务器内存；智能识别 SSH 客户端 IP 作为 RTT 测试目标
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

1. **环境检测**: 检查 root 权限，获取内存和 RTT
2. **参数确认**: 展示并允许修改检测值
3. **科学计算**: 基于 `min(2*BDP, 3%RAM, 64MB)` 策略确定最优缓冲区
4. **清理冲突**: 备份并注释冲突配置
5. **应用配置**: 写入 `/etc/sysctl.d/999-net-bbr-fq.conf` 并执行
6. **结果验证**: 打印生效的网络参数

## 优化项一览

| 分类           | 参数                               | 说明                              |
| -------------- | ---------------------------------- | --------------------------------- |
| **拥塞控制**   | BBR + fq                           | Google 推荐组合                   |
| **TCP 缓冲区** | `tcp_rmem` / `tcp_wmem`            | 基于 BDP 动态计算 max 值          |
| **核心缓冲区** | `rmem_max` / `wmem_max`            | 上限 `min(2×BDP, 3%RAM, 64MB)`    |
| **TCP 性能**   | `tcp_fastopen=7`                   | 客户端+服务端+无cookie TFO        |
|                | `tcp_notsent_lowat=131072`         | Cloudflare 推荐，提升发送吞吐     |
|                | `tcp_moderate_rcvbuf=1`            | 缓冲区自动调节安全网              |
|                | `tcp_slow_start_after_idle=0`      | 禁用空闲后慢启动                  |
| **连接队列**   | `somaxconn` / `netdev_max_backlog` | 根据内存/带宽动态分档             |
| **软中断**     | `netdev_budget=600`                | 提升软中断处理效率                |
| **UDP 优化**   | `udp_rmem_min=16384`               | QUIC/WireGuard 友好               |
|                | `udp_mem`                          | 根据内存动态计算全局 UDP 内存上限 |

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

1. 检查内核版本（需要 4.9+）：`uname -r`
2. 检查 BBR 模块：`modprobe tcp_bbr && lsmod | grep bbr`
3. 部分云服务商的内核可能未编译 BBR 支持

### 配置未持久化

确保配置文件存在：`cat /etc/sysctl.d/999-net-bbr-fq.conf`

### 如何恢复原配置

脚本会自动备份冲突文件为 `*.bak.时间戳` 格式，可手动恢复。
