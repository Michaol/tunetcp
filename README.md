[![许可证: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](https://www.gnu.org/licenses/gpl-3.0) ![Badge](https://hitscounter.dev/api/hit?url=https%3A%2F%2Fgithub.com%2FMichaol%2tunetcp&label=&icon=github&color=%23198754&message=&style=flat&tz=Asia%2FShanghai)

## TuneTCP，根据GPTADM在NodeSeek发布的源码修改而来的TCP优化脚本

一个为 Linux 服务器设计的智能、交互式 TCP 网络性能优化脚本，旨在自动化启用 BBRv1 拥塞控制算法和 FQ (Fair Queue) 包调度器，并根据实际环境科学地配置 TCP 缓冲区，从而充分利用服务器带宽，改善网络传输效率。

--------------------

主要特性

- 智能检测: 自动检测服务器总内存；智能识别 SSH 客户端 IP 作为首选延迟（RTT）测试目标，实现对真实网络环境的精准测量。
- 交互式体验: 脚本会呈现所有自动检测到的值，并允许用户在执行前进行手动修改或确认，兼顾自动化与灵活性。
- 自动冲突处理: 自动扫描并处理 /etc/sysctl.d/ 和 /etc/sysctl.conf 中现有的冲突网络配置，通过备份并重命名的方式解决配置覆盖问题，而非粗暴删除。
- 即时生效与持久化: 配置不仅通过 sysctl 命令即时生效，还会写入到 /etc/sysctl.d/ 目录下，确保服务器重启后配置依然有效。
- 安全优先: 脚本会检查是否以 root 权限运行，并且所有修改/移除旧配置文件的操作都以带时间戳的备份为前提，方便回滚。


一键运行

请以 root 用户身份登录您的 Linux 服务器，然后执行以下命令：

```使用 Wget:
wget -qO tunetcp.sh https://raw.githubusercontent.com/Michaol/tunetcp/main/tunetcp.sh && chmod +x tunetcp.sh && ./tunetcp.sh
```

脚本工作流程

1. 环境检测:
   - 检查是否为 root 用户。
   - 自动获取系统总内存 (GiB)。
   - 尝试从 $SSH_CONNECTION 环境变量中获取客户端 IP。若失败，则提示用户手动输入一个 IP 进行延迟测试。

2. 参数确认:
   - 向用户展示自动检测到的 内存、带宽 (默认 1000 Mbps) 和 RTT (延迟)，并请求用户确认或修改。

3. 科学计算:
   - 基于最终确认的参数，计算带宽时延积 (BDP)。
   - 根据 min(2*BDP, 3%总内存, 64MB) 的安全策略，确定最优的 TCP 缓冲区大小，并将其规整到 {4,8,16,32,64}MB 的标准档位。

4. 清理冲突:
   - 备份并注释掉 /etc/sysctl.conf 文件中的冲突行。
   - 遍历 /etc/sysctl.d/ 目录，将包含冲突键的旧配置文件重命名为 *.conf.bak.时间戳。

5. 应用配置:
   - 创建新的配置文件 /etc/sysctl.d/999-net-bbr-fq.conf 并写入所有优化参数。
   - 执行 sysctl --system 使配置立即生效。

6. 结果验证:
   - 打印最终生效的核心网络参数值，供用户核对。
