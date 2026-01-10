# TuneTCP

[![许可证: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](https://www.gnu.org/licenses/gpl-3.0) ![Badge](https://hitscounter.dev/api/hit?url=https%3A%2F%2Fgithub.com%2FMichaol%2Ftunetcp&label=&icon=github&color=%23198754&message=&style=flat&tz=Asia%2FShanghai)

一个为 Linux 服务器设计的**最激进** TCP/UDP 网络性能优化脚本。自动启用 BBR 拥塞控制和 FQ 包调度器，采用激进策略配置 TCP 缓冲区，充分释放服务器网络性能。

> **v3.0 重大更新**: 从平衡策略转向性能优先，针对 512MB-2GB 内存 VPS 优化，采用分级激进策略。

## 主要特性

- **激进优化策略**: 性能优先，最大化网络吞吐量
  - 缓冲区: `max(4*BDP, 分级最小值)`, 根据内存分级动态上限
  - 队列大小: 固定使用最大值 65535
  - 超时参数: 最小化延迟，激进连接复用
- **内存分级优化**: 针对 512MB-2GB 内存 VPS 特别优化
  - 512MB-1GB: 保守激进 (64-128MB 缓冲区)
  - 1-2GB: 标准激进 (128-256MB 缓冲区)
  - 2GB+: 完全激进 (256-512MB 缓冲区)
- **智能检测**: 自动检测服务器内存；智能识别 SSH 客户端 IP 作为 RTT 测试目标
- **BBR 版本检测**: 自动检测并启用 BBR v1/v2/v3 (内核支持的最高版本)
- **双栈支持**: 同时优化 IPv4 和 IPv6 的 TCP/UDP（单栈和双栈服务器均适用)
- **交互式体验**: 展示所有检测值，允许手动修改或确认
- **非交互模式**: 支持命令行参数，适合脚本化部署
- **自动冲突处理**: 扫描并处理现有冲突配置，通过备份解决配置覆盖问题
- **即时生效与持久化**: 配置即时生效并写入 `/etc/sysctl.d/`，重启后依然有效
- **安全优先**: 提供内核版本（4.9+）兼容性检查，脚本安全加固 `pipefail`
- **全平台兼容**: 严格遵循 **POSIX** 标准，完美支持 Debian/Ubuntu/CentOS/Fedora/Alpine (BusyBox) 等
- **预览模式**: 新增 `--dry-run` 参数，无需修改系统即可预览生成的配置
- **性能优化**: 动态正则表达式生成，减少冗余调用，系统资源占用极低
- **调试模式**: 提供 `-d/--debug` 参数，详细记录执行流与决策逻辑

## 一键运行

以 root 用户身份登录 Linux 服务器，执行以下命令：

```bash
# 交互模式（推荐，支持确认参数和RTT检测）
wget -qO tunetcp.sh https://raw.githubusercontent.com/Michaol/tunetcp/main/tunetcp.sh && chmod +x tunetcp.sh && sudo ./tunetcp.sh

# 非交互模式（使用默认参数直接应用）
wget -qO tunetcp.sh https://raw.githubusercontent.com/Michaol/tunetcp/main/tunetcp.sh && chmod +x tunetcp.sh && sudo ./tunetcp.sh -y
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

# 卸载配置
./tunetcp.sh --uninstall
```

## 工作流程

1. **环境检测**: 检查 root 权限，获取内存和 RTT
2. **参数确认**: 展示并允许修改检测值
3. **激进计算**: 基于 `max(4*BDP, RAM百分比, 分级最小值)` 策略确定缓冲区
   - 512MB-1GB 内存: 8% RAM, 最小 64MB, 上限 128MB
   - 1-2GB 内存: 10% RAM, 最小 128MB, 上限 256MB
   - 2GB+ 内存: 10% RAM, 最小 256MB, 上限 512MB
4. **清理冲突**: 备份并注释冲突配置
5. **应用配置**: 写入 `/etc/sysctl.d/999-net-bbr-fq.conf` 并执行
6. **队列优化**: 应用激进的 FQ 队列调度器参数
7. **结果验证**: 打印生效的网络参数

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

### v3.0 激进策略说明

**Q: v3.0 和旧版本有什么区别？**  
A: v3.0 采用性能优先策略，主要变化：

- 缓冲区从 `min(2*BDP, 3%RAM, 64MB)` 改为 `max(4*BDP, 分级最小值)`
- 队列大小从动态调整改为固定最大值 65535
- 超时参数最小化，连接复用更激进
- 添加大量高级 TCP/UDP 优化参数

**Q: 会占用多少内存？**  
A: 根据内存分级：

- 512MB-1GB VPS: 最多占用约 128MB (在高流量时)
- 1-2GB VPS: 最多占用约 256MB (在高流量时)
- 2GB+ VPS: 最多占用约 512MB (在高流量时)

实际占用取决于并发连接数和网络流量。

**Q: 如果出现内存不足怎么办？**  
A: 运行 `./tunetcp.sh --uninstall` 恢复默认配置，或者使用旧版本(v2.x)。

### BBR 未生效

1. 检查内核版本（需要 4.9+）：`uname -r`
2. 检查 BBR 模块：`modprobe tcp_bbr && lsmod | grep bbr`
3. 部分云服务商的内核可能未编译 BBR 支持

### 配置未持久化

确保配置文件存在：`cat /etc/sysctl.d/999-net-bbr-fq.conf`

### 如何恢复原配置

脚本会自动备份冲突文件为 `*.bak.时间戳` 格式，可手动恢复。
