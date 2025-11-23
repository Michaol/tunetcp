#!/usr/bin/env sh
set -eu

# =========================================================
# TuneTCP (兼容 Alpine Linux 的 POSIX-compliant 版本)
# - Shell改为/bin/sh, 兼容BusyBox ash
# - 移除了所有bash特有的语法 (read -p, [[ ]], =~, shopt)
# - 新增: 使用自定义函数兼容BusyBox的sysctl命令
# =========================================================

# --- 辅助函数 (输出重定向到 stderr, 避免污染返回值) ---
note() { printf '\033[1;34m[i]\033[0m %s\n' "$*" >&2; }
ok()   { printf '\033[1;32m[OK]\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
bad()  { printf '\033[1;31m[!!]\033[0m %s\n' "$*" >&2; exit 1; }

# --- 自动检测函数 (兼容 Alpine) ---
get_mem_gib() {
  mem_kib=$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)
  awk -v kib="$mem_kib" 'BEGIN {printf "%.2f", kib / 1024 / 1024}'
}

get_rtt_ms() {
  ping_target=""
  ping_desc=""

  if [ -n "${SSH_CONNECTION-}" ]; then
    ping_target=$(echo "$SSH_CONNECTION" | awk '{print $1}')
    ping_desc="SSH 客户端 ${ping_target}"
    note "成功从 SSH 连接中自动检测到客户端 IP: ${ping_target}"
  else
    note "未检测到 SSH 连接环境，需要您提供一个客户机IP。"
    printf "请输入一个代表性客户机IP进行ping测试 (直接回车则ping 1.1.1.1): "
    read -r client_ip
    if [ -n "$client_ip" ]; then
      ping_target="$client_ip"
      ping_desc="客户机IP ${ping_target}"
    fi
  fi
  
  if [ -z "$ping_target" ]; then
    ping_target="1.1.1.1"
    ping_desc="公共地址 ${ping_target} (通用网络)"
    note "未提供IP，将使用 ${ping_desc} 进行测试。"
  fi

  note "正在通过 ping ${ping_desc} 测试网络延迟..."
  ping_result=$(ping -c 4 -W 2 "$ping_target" 2>/dev/null | tail -1 | awk -F'/' '{print $5}')
  
  is_ping_num=$(echo "$ping_result" | awk '/^[0-9]+([.][0-9]+)?$/ {print 1}')
  if [ "$is_ping_num" = "1" ]; then
    ok "检测到平均 RTT: ${ping_result} ms"
    echo "$ping_result" | awk '{printf "%.0f\n", $1}'
  else
    warn "Ping ${ping_target} 失败，无法检测 RTT。将使用默认值 150 ms。"
    echo "150"
  fi
}

# --- 新增: 兼容BusyBox的sysctl应用函数 ---
apply_sysctl_settings() {
    note "正在应用 sysctl 配置 (BusyBox 兼容模式)..."
    dirs="/run/sysctl.d /etc/sysctl.d /usr/local/lib/sysctl.d /usr/lib/sysctl.d /lib/sysctl.d"
    files_to_load=""
    
    for dir in $dirs; do
        if [ -d "$dir" ]; then
            for conf_file in "$dir"/*.conf; do
                if [ -e "$conf_file" ] || [ -L "$conf_file" ]; then
                    files_to_load="$files_to_load $conf_file"
                fi
            done
        fi
    done
    
    if [ -f "/etc/sysctl.conf" ]; then
        files_to_load="$files_to_load /etc/sysctl.conf"
    fi
    
    if [ -n "$files_to_load" ]; then
        sysctl -e -p $files_to_load >/dev/null
    else
        ok "未找到 sysctl 配置文件。" >&2
    fi
}


# --- 主要变量初始化 ---
MEM_G=$(get_mem_gib)
RTT_ms=$(get_rtt_ms)
BW_Mbps=1000 # 带宽默认值

# --- 交互式确认与修改循环 ---
while true; do
    command -v clear >/dev/null && clear
    note "请检查并确认以下网络优化参数："
    printf %s\\n "--------------------------------------------------"
    printf "1. 内存大小     : %s GiB (根据系统自动检测)\n" "$MEM_G"
    printf "2. 带宽 (出口)  : %s Mbps (请按需修改为真实带宽)\n" "$BW_Mbps"
    printf "3. 网络延迟(RTT): %s ms (根据客户端自动检测)\n" "$RTT_ms"
    printf %s\\n "--------------------------------------------------"
    printf "直接按 [Enter] 应用设置, 或输入数字 [1-3] 修改, [q] 退出: "
    read -r choice </dev/tty

    case "$choice" in
        "")
            note "参数已确认，开始执行优化..."
            break
            ;;
        1)
            printf "请输入新的内存大小 (GiB) [%s]: " "$MEM_G"
            read -r new_mem </dev/tty
            MEM_G="${new_mem:-$MEM_G}"
            ;;
        2)
            printf "请输入您的服务器出口带宽 (Mbps) [%s]: " "$BW_Mbps"
            read -r new_bw </dev/tty
            BW_Mbps="${new_bw:-$BW_Mbps}"
            ;;
        3)
            printf "请输入新的网络延迟 RTT (ms) [%s]: " "$RTT_ms"
            read -r new_rtt </dev/tty
            RTT_ms="${new_rtt:-$RTT_ms}"
            ;;
        q|Q)
            note "用户取消操作。"
            exit 0
            ;;
        *)
            warn "无效输入，请重试。"
            sleep 1
            ;;
    esac
done


# --- 后续流程 ---
is_num() { echo "$1" | awk '/^[0-9]+([.][0-9]+)?$/ {print 1}'; }
is_int() { echo "$1" | awk '/^[0-9]+$/ {print 1}'; }
if [ ! "$(is_num "$MEM_G")" = "1" ] || [ ! "$(is_int "$BW_Mbps")" = "1" ] || [ ! "$(is_num "$RTT_ms")" = "1" ]; then
    bad "参数包含无效的非数字输入，脚本终止。"
fi

SYSCTL_TARGET="/etc/sysctl.d/999-net-bbr-fq.conf"
KEY_REGEX='^net\.core\.default_qdisc|^net\.core\.rmem_max|^net\.core\.wmem_max|^net\.core\.rmem_default|^net\.core\.wmem_default|^net\.ipv4\.tcp_rmem|^net\.ipv4\.tcp_wmem|^net\.ipv4\.tcp_congestion_control|^net\.ipv4\.tcp_slow_start_after_idle|^net\.ipv4\.tcp_notsent_lowat|^net\.core\.somaxconn|^net\.ipv4\.tcp_max_syn_backlog|^net\.core\.netdev_max_backlog|^net\.ipv4\.ip_local_port_range|^net\.ipv4\.udp_rmem_min|^net\.ipv4\.udp_wmem_min|^net\.core\.optmem_max'

require_root() { if [ "$(id -u)" -ne 0 ]; then bad "请以 root 运行"; fi; }
default_iface(){ ip -o -4 route show to default 2>/dev/null | awk '{print $5}' | head -1 || true; }

# ---- 计算（逐步校验）----
BDP_BYTES=$(awk -v bw="$BW_Mbps" -v rtt="$RTT_ms" 'BEGIN{ printf "%.0f", bw*125*rtt }')
MEM_BYTES=$(awk -v g="$MEM_G" 'BEGIN{ printf "%.0f", g*1024*1024*1024 }')
TWO_BDP=$(( BDP_BYTES*2 ))
RAM3_BYTES=$(awk -v m="$MEM_BYTES" 'BEGIN{ printf "%.0f", m*0.03 }')
CAP64=$(( 64*1024*1024 ))
MAX_NUM_BYTES=$(awk -v a="$TWO_BDP" -v b="$RAM3_BYTES" -v c="$CAP64" 'BEGIN{ m=a; if(b<m)m=b; if(c<m)m=c; printf "%.0f", m }')

bucket_le_mb() {
  mb="${1:-0}"
  if [ "$mb" -ge 64 ]; then echo 64
  elif [ "$mb" -ge 32 ]; then echo 32
  elif [ "$mb" -ge 16 ]; then echo 16
  elif [ "$mb" -ge 8 ]; then echo 8
  elif [ "$mb" -ge 4 ]; then echo 4
  else echo 4
  fi
}
MAX_MB_NUM=$(( MAX_NUM_BYTES/1024/1024 ))
MAX_MB=$(bucket_le_mb "$MAX_MB_NUM")
MAX_BYTES=$(( MAX_MB*1024*1024 ))

if [ "$MAX_MB" -ge 32 ]; then
  DEF_R=262144; DEF_W=524288
elif [ "$MAX_MB" -ge 8 ]; then
  DEF_R=131072; DEF_W=262144
else
  DEF_R=131072; DEF_W=131072
fi

TCP_RMEM_MIN=4096; TCP_RMEM_DEF=87380; TCP_RMEM_MAX=$MAX_BYTES
TCP_WMEM_MIN=4096; TCP_WMEM_DEF=65536; TCP_WMEM_MAX=$MAX_BYTES

# ---- 冲突清理 ----
comment_conflicts_in_sysctl_conf() {
  f="/etc/sysctl.conf"
  [ -f "$f" ] || { ok "/etc/sysctl.conf 不存在"; return 0; }
  if grep -E "$KEY_REGEX" "$f" >/dev/null; then
    backup_file="${f}.bak.$(date +%Y%m%d-%H%M%S)"
    note "发现冲突，备份 /etc/sysctl.conf 至 ${backup_file}"
    cp -a "$f" "$backup_file"
    
    note "注释 /etc/sysctl.conf 中的冲突键"
    sed_script=""
    for key in $(echo "$KEY_REGEX" | tr '|' ' '); do
        # Strip leading ^ from key for sed pattern to avoid matching literal ^
        clean_key="${key#^}"
        sed_script="${sed_script}s/^[[:space:]]*${clean_key}/# &/;"
    done
    # Busybox sed's -i needs a suffix on some versions, safer to use tmp file
    sed "$sed_script" "$f" > "${f}.tmp" && mv "${f}.tmp" "$f"
    ok "已注释掉冲突键"
  else
    ok "/etc/sysctl.conf 无冲突键"
  fi
}

delete_conflict_files_in_dir() {
  dir="$1"
  [ -d "$dir" ] || { ok "$dir 不存在"; return 0; }
  moved=0
  backup_suffix=".bak.$(date +%Y%m%d-%H%M%S)"
  for f in "$dir"/*.conf; do
    [ -e "$f" ] || [ -L "$f" ] || continue
    [ "$(readlink -f "$f")" = "$(readlink -f "$SYSCTL_TARGET")" ] && continue
    if grep -E "$KEY_REGEX" "$f" >/dev/null; then
      backup_file="${f}${backup_suffix}"
      mv -- "$f" "$backup_file"
      note "已备份并移除冲突文件: $f -> $backup_file"
      moved=1
    fi
  done
  if [ "$moved" -eq 1 ]; then ok "$dir 中的冲突文件已处理"; else ok "$dir 无需处理"; fi
}

scan_conflicts_ro() {
  dir="$1"
  [ -d "$dir" ] || { ok "$dir 不存在"; return 0; }
  if grep -rE "$KEY_REGEX" "$dir" >/dev/null 2>&1; then
    warn "发现潜在冲突（只提示不改）：$dir"
    grep -rnhE "$KEY_REGEX" "$dir" 2>/dev/null || true
  else
    ok "$dir 未发现冲突"
  fi
}

require_root
note "步骤A：备份并注释 /etc/sysctl.conf 冲突键"
comment_conflicts_in_sysctl_conf

note "步骤B：备份并移除 /etc/sysctl.d 下含冲突键的旧文件"
delete_conflict_files_in_dir "/etc/sysctl.d"

note "步骤C：扫描其他目录（只读提示，不改）"
true
scan_conflicts_ro "/usr/local/lib/sysctl.d"
scan_conflicts_ro "/usr/lib/sysctl.d"
scan_conflicts_ro "/lib/sysctl.d"
scan_conflicts_ro "/run/sysctl.d"

# ---- 启用 BBR 模块（若为内置则无影响）----
if command -v modprobe >/dev/null 2>&1; then modprobe tcp_bbr 2>/dev/null || true; fi

# ---- 写入并应用 ----
tmpf="$(mktemp)"
BDP_MB_display=$(awk -v b="$BDP_BYTES" 'BEGIN{ printf "%.2f", b/1024/1024 }')
printf '# Auto-generated by TuneTCP (https://github.com/Michaol/tunetcp)\n' > "$tmpf"
printf '# Inputs: MEM_G=%sGiB, BW=%sMbps, RTT=%sms\n' "$MEM_G" "$BW_Mbps" "$RTT_ms" >> "$tmpf"
printf '# BDP: %s bytes (~%s MB)\n' "$BDP_BYTES" "$BDP_MB_display" >> "$tmpf"
printf '# Caps: min(2*BDP, 3%%RAM, 64MB) -> Bucket %s MB\n' "$MAX_MB" >> "$tmpf"
printf '\n' >> "$tmpf"
printf 'net.core.default_qdisc = fq\n' >> "$tmpf"
printf 'net.ipv4.tcp_congestion_control = bbr\n' >> "$tmpf"
printf '\n' >> "$tmpf"
printf 'net.core.rmem_default = %s\n' "$DEF_R" >> "$tmpf"
printf 'net.core.wmem_default = %s\n' "$DEF_W" >> "$tmpf"
printf 'net.core.rmem_max = %s\n' "$MAX_BYTES" >> "$tmpf"
printf 'net.core.wmem_max = %s\n' "$MAX_BYTES" >> "$tmpf"
printf '\n' >> "$tmpf"
printf 'net.ipv4.tcp_rmem = %s %s %s\n' "$TCP_RMEM_MIN" "$TCP_RMEM_DEF" "$TCP_RMEM_MAX" >> "$tmpf"
printf 'net.ipv4.tcp_wmem = %s %s %s\n' "$TCP_WMEM_MIN" "$TCP_WMEM_DEF" "$TCP_WMEM_MAX" >> "$tmpf"
printf '\n' >> "$tmpf"
printf 'net.ipv4.tcp_mtu_probing = 1\n' >> "$tmpf"
printf 'net.ipv4.tcp_slow_start_after_idle = 0\n' >> "$tmpf"
printf 'net.ipv4.tcp_notsent_lowat = 16384\n' >> "$tmpf"
printf 'net.core.somaxconn = 8192\n' >> "$tmpf"
printf 'net.ipv4.tcp_max_syn_backlog = 8192\n' >> "$tmpf"
printf 'net.core.netdev_max_backlog = 16384\n' >> "$tmpf"
printf 'net.ipv4.ip_local_port_range = 1024 65535\n' >> "$tmpf"
printf 'net.ipv4.udp_rmem_min = 8192\n' >> "$tmpf"
printf 'net.ipv4.udp_wmem_min = 8192\n' >> "$tmpf"
printf 'net.core.optmem_max = 65536\n' >> "$tmpf"
printf 'net.ipv4.tcp_fastopen = 3\n' >> "$tmpf"

install -m 0644 "$tmpf" "$SYSCTL_TARGET"
rm -f "$tmpf"

# 修改: 调用新的兼容性函数
apply_sysctl_settings

IFACE="$(default_iface)"
if command -v tc >/dev/null 2>&1 && [ -n "${IFACE-}" ]; then
  note "为接口 ${IFACE} 设置 fq 队列..."
  tc qdisc replace dev "$IFACE" root fq 2>/dev/null || true
fi

# ---- 结果输出 ----
ok "TCP 优化配置已成功应用！"
echo
echo "==== [ TuneTCP 优化结果 ] ===="
echo

BDP_MB=$(awk -v b="$BDP_BYTES" 'BEGIN{ printf "%.2f", b/1024/1024 }')
GREEN="\033[1;32m"
RESET="\033[0m"

printf '%b[+] I. 核心参数摘要%b\n' "$GREEN" "$RESET"
printf "    - %-12s : %s\n" "输入内存" "${MEM_G} GiB"
printf "    - %-12s : %s\n" "输入带宽" "${BW_Mbps} Mbps"
printf "    - %-12s : %s\n" "输入延迟" "${RTT_ms} ms"
printf "    - %-12s : %s\n" "计算BDP" "${BDP_MB} MB"
printf "    - %-12s : %s\n" "最终缓冲区" "${MAX_MB} MB"
echo

printf '%b[+] II. 内核参数验证%b\n' "$GREEN" "$RESET"
printf "    - %-25s : %s\n" "TCP 拥塞控制" "$(sysctl -n net.ipv4.tcp_congestion_control)"
printf "    - %-25s : %s\n" "默认包调度器" "$(sysctl -n net.core.default_qdisc)"
printf "    - %-25s : %s (%s MB)\n" "最大接收缓冲区" "$(sysctl -n net.core.rmem_max)" "$MAX_MB"
printf "    - %-25s : %s (%s MB)\n" "最大发送缓冲区" "$(sysctl -n net.core.wmem_max)" "$MAX_MB"
printf "    - %-25s : %s\n" "TCP 接收缓冲区 (min/def/max)" "$(sysctl -n net.ipv4.tcp_rmem)"
printf "    - %-25s : %s\n" "TCP 发送缓冲区 (min/def/max)" "$(sysctl -n net.ipv4.tcp_wmem)"
printf "    - %-25s : %s\n" "TCP 慢启动闲置重置" "$(sysctl -n net.ipv4.tcp_slow_start_after_idle)"
printf "    - %-25s : %s\n" "TCP 未发送低水位" "$(sysctl -n net.ipv4.tcp_notsent_lowat)"
printf "    - %-25s : %s\n" "最大连接监听队列" "$(sysctl -n net.core.somaxconn)"
printf "    - %-25s : %s\n" "最大 SYN 积压队列" "$(sysctl -n net.ipv4.tcp_max_syn_backlog)"
printf "    - %-25s : %s\n" "网卡最大接收积压" "$(sysctl -n net.core.netdev_max_backlog)"
printf "    - %-25s : %s\n" "本地端口范围" "$(sysctl -n net.ipv4.ip_local_port_range)"
printf "    - %-25s : %s\n" "UDP 最小接收缓冲" "$(sysctl -n net.ipv4.udp_rmem_min)"
printf "    - %-25s : %s\n" "UDP 最小发送缓冲" "$(sysctl -n net.ipv4.udp_wmem_min)"
echo

if command -v tc >/dev/null 2>&1 && [ -n "${IFACE-}" ]; then
    printf '%b[+] III. 网络接口验证%b\n' "$GREEN" "$RESET"
    printf "    - 接口 %-10s : %s\n" "${IFACE} 队列" "$(tc qdisc show dev "$IFACE" | head -1)"
fi

echo "=================================="
echo
note "复核步骤在 BusyBox 环境下已简化，以上参数即为最终生效值。"
