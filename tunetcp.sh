#!/usr/bin/env bash
set -euo pipefail

# =========================================================
# TuneTCP (交互式菜单最终版)
# - 新增：执行前汇总所有参数，提供交互式菜单供用户最终确认和修改
# - 智能：优先从SSH连接中获取客户端IP进行RTT测试
# - 安全：所有清理操作前自动备份
# =========================================================

# --- 辅助函数 (输出重定向到 stderr, 避免污染返回值) ---
note() { echo -e "\033[1;34m[i]\033[0m $*" >&2; }
ok()   { echo -e "\033[1;32m[OK]\033[0m $*" >&2; }
warn() { echo -e "\033[1;33m[!]\033[0m $*" >&2; }
bad()  { echo -e "\033[1;31m[!!]\033[0m $*" >&2; exit 1; }

# --- 自动检测函数 ---
get_mem_gib() {
  local mem_bytes
  mem_bytes=$(free -b | awk '/^Mem:/ {print $2}')
  awk -v bytes="$mem_bytes" 'BEGIN {printf "%.2f", bytes / 1024^3}'
}

get_rtt_ms() {
  local ping_target=""
  local ping_desc=""

  if [ -n "${SSH_CONNECTION-}" ]; then
    ping_target=$(echo "$SSH_CONNECTION" | awk '{print $1}')
    ping_desc="SSH 客户端 ${ping_target}"
    note "成功从 SSH 连接中自动检测到客户端 IP: ${ping_target}"
  else
    note "未检测到 SSH 连接环境，需要您提供一个客户机IP。"
    local client_ip
    read -r -p "请输入一个代表性客户机IP进行ping测试 (直接回车则ping 1.1.1.1): " client_ip
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
  local ping_result
  ping_result=$(ping -c 4 -W 2 "$ping_target" 2>/dev/null | tail -1 | awk -F'/' '{print $5}')
  
  if [[ "$ping_result" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    ok "检测到平均 RTT: ${ping_result} ms"
    printf "%.0f" "$ping_result"
  else
    warn "Ping ${ping_target} 失败，无法检测 RTT。将使用默认值 150 ms。"
    echo "150"
  fi
}

# --- 主要变量初始化 ---
MEM_G=$(get_mem_gib)
RTT_ms=$(get_rtt_ms)
BW_Mbps=1000 # 带宽默认值

# --- 全新交互式确认与修改循环 ---
while true; do
    clear
    note "请检查并确认以下网络优化参数："
    echo "--------------------------------------------------"
    echo "1. 内存大小     : ${MEM_G} GiB (根据系统自动检测)"
    echo "2. 带宽 (出口)  : ${BW_Mbps} Mbps (请按需修改为真实带宽)"
    echo "3. 网络延迟(RTT): ${RTT_ms} ms (根据客户端自动检测)"
    echo "--------------------------------------------------"
    read -r -p "直接按 [Enter] 应用设置, 或输入数字 [1-3] 修改, [q] 退出: " choice

    case "$choice" in
        "")
            note "参数已确认，开始执行优化..."
            break
            ;;
        1)
            read -r -p "请输入新的内存大小 (GiB) [${MEM_G}]: " new_mem
            MEM_G="${new_mem:-$MEM_G}"
            ;;
        2)
            read -r -p "请输入您的服务器出口带宽 (Mbps) [${BW_Mbps}]: " new_bw
            BW_Mbps="${new_bw:-$BW_Mbps}"
            ;;
        3)
            read -r -p "请输入新的网络延迟 RTT (ms) [${RTT_ms}]: " new_rtt
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


# --- 后续流程不变 ---
is_num() { [[ "${1:-}" =~ ^[0-9]+([.][0-9]+)?$ ]]; }
is_int() { [[ "${1:-}" =~ ^[0-9]+$ ]]; }
if ! is_num "$MEM_G" || ! is_int "$BW_Mbps" || ! is_num "$RTT_ms"; then
    bad "参数包含无效的非数字输入，脚本终止。"
fi

SYSCTL_TARGET="/etc/sysctl.d/999-net-bbr-fq.conf"
KEY_REGEX='^(net\.core\.default_qdisc|net\.core\.rmem_max|net\.core\.wmem_max|net\.core\.rmem_default|net\.core\.wmem_default|net\.ipv4\.tcp_rmem|net\.ipv4\.tcp_wmem|net\.ipv4\.tcp_congestion_control)[[:space:]]*='

require_root() { if [ "${EUID:-$(id -u)}" -ne 0 ]; then bad "请以 root 运行"; fi; }
default_iface(){ ip -o -4 route show to default 2>/dev/null | awk '{print $5}' | head -1 || true; }

# ---- 计算（逐步校验）----
BDP_BYTES=$(awk -v bw="$BW_Mbps" -v rtt="$RTT_ms" 'BEGIN{ printf "%.0f", bw*125*rtt }')
MEM_BYTES=$(awk -v g="$MEM_G" 'BEGIN{ printf "%.0f", g*1024*1024*1024 }')
TWO_BDP=$(( BDP_BYTES*2 ))
RAM3_BYTES=$(awk -v m="$MEM_BYTES" 'BEGIN{ printf "%.0f", m*0.03 }')
CAP64=$(( 64*1024*1024 ))
MAX_NUM_BYTES=$(awk -v a="$TWO_BDP" -v b="$RAM3_BYTES" -v c="$CAP64" 'BEGIN{ m=a; if(b<m)m=b; if(c<m)m=c; printf "%.0f", m }')

bucket_le_mb() {
  local mb="${1:-0}"
  if   [ "$mb" -ge 64 ]; then echo 64
  elif [ "$mb" -ge 32 ]; then echo 32
  elif [ "$mb" -ge 16 ]; then echo 16
  elif [ "$mb" -ge  8 ]; then echo 8
  elif [ "$mb" -ge  4 ]; then echo 4
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
  local f="/etc/sysctl.conf"
  [ -f "$f" ] || { ok "/etc/sysctl.conf 不存在"; return 0; }
  if grep -Eq "$KEY_REGEX" "$f"; then
    local backup_file="${f}.bak.$(date +%Y%m%d-%H%M%S)"
    note "发现冲突，备份 /etc/sysctl.conf 至 ${backup_file}"
    cp -a "$f" "$backup_file"
    
    note "注释 /etc/sysctl.conf 中的冲突键"
    awk -v re="$KEY_REGEX" '
      $0 ~ re && $0 !~ /^[[:space:]]*#/ { print "# " $0; next }
      { print $0 }
    ' "$f" > "${f}.tmp.$$"
    install -m 0644 "${f}.tmp.$$" "$f"
    rm -f "${f}.tmp.$$"
    ok "已注释掉冲突键"
  else
    ok "/etc/sysctl.conf 无冲突键"
  fi
}

delete_conflict_files_in_dir() {
  local dir="$1"
  [ -d "$dir" ] || { ok "$dir 不存在"; return 0; }
  shopt -s nullglob
  local moved=0
  local backup_suffix=".bak.$(date +%Y%m%d-%H%M%S)"
  for f in "$dir"/*.conf; do
    [ "$(readlink -f "$f")" = "$(readlink -f "$SYSCTL_TARGET")" ] && continue
    if grep -Eq "$KEY_REGEX" "$f"; then
      local backup_file="${f}${backup_suffix}"
      mv -- "$f" "$backup_file"
      note "已备份并移除冲突文件: $f -> $backup_file"
      moved=1
    fi
  done
  shopt -u nullglob
  [ "$moved" -eq 1 ] && ok "$dir 中的冲突文件已处理" || ok "$dir 无需处理"
}

scan_conflicts_ro() {
  local dir="$1"
  [ -d "$dir" ] || { ok "$dir 不存在"; return 0; }
  if grep -RIlEq "$KEY_REGEX" "$dir" 2>/dev/null; then
    warn "发现潜在冲突（只提示不改）：$dir"
    grep -RhnE "$KEY_REGEX" "$dir" 2>/dev/null || true
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
/usr/bin/true
scan_conflicts_ro "/usr/local/lib/sysctl.d"
scan_conflicts_ro "/usr/lib/sysctl.d"
scan_conflicts_ro "/lib/sysctl.d"
scan_conflicts_ro "/run/sysctl.d"

# ---- 启用 BBR 模块（若为内置则无影响）----
if command -v modprobe >/dev/null 2>&1; then modprobe tcp_bbr 2>/dev/null || true; fi

# ---- 写入并应用 ----
tmpf="$(mktemp)"
cat >"$tmpf" <<EOF
# Auto-generated by TuneTCP (https://github.com/Michaol/tunetcp)
# Inputs: MEM_G=${MEM_G}GiB, BW=${BW_Mbps}Mbps, RTT=${RTT_ms}ms
# BDP: ${BDP_BYTES} bytes (~$(awk -v b="$BDP_BYTES" 'BEGIN{ printf "%.2f", b/1024/1024 }') MB)
# Caps: min(2*BDP, 3%RAM, 64MB) -> Bucket ${MAX_MB} MB

net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

net.core.rmem_default = ${DEF_R}
net.core.wmem_default = ${DEF_W}
net.core.rmem_max = ${MAX_BYTES}
net.core.wmem_max = ${MAX_BYTES}

net.ipv4.tcp_rmem = ${TCP_RMEM_MIN} ${TCP_RMEM_DEF} ${TCP_RMEM_MAX}
net.ipv4.tcp_wmem = ${TCP_WMEM_MIN} ${TCP_WMEM_DEF} ${TCP_WMEM_MAX}

net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_fastopen = 3
EOF
install -m 0644 "$tmpf" "$SYSCTL_TARGET"
rm -f "$tmpf"

note "正在应用 sysctl 配置..."
sysctl --system >/dev/null

IFACE="$(default_iface)"
if command -v tc >/dev/null 2>&1 && [ -n "${IFACE:-}" ]; then
  note "为接口 ${IFACE} 设置 fq 队列..."
  tc qdisc replace dev "$IFACE" root fq 2>/dev/null || true
fi

ok "TCP 优化配置已成功应用！"
echo
echo "==== [ TuneTCP 优化结果 ] ===="
echo

# 计算BDP（MB）以便显示
BDP_MB=$(awk -v b="$BDP_BYTES" 'BEGIN{ printf "%.2f", b/1024/1024 }')

# 定义一些颜色
GREEN="\033[1;32m"
RESET="\033[0m"

# I. 核心参数摘要
echo -e "${GREEN}[+] I. 核心参数摘要${RESET}"
printf "    - %-12s : %s\n" "输入内存" "${MEM_G} GiB"
printf "    - %-12s : %s\n" "输入带宽" "${BW_Mbps} Mbps"
printf "    - %-12s : %s\n" "输入延迟" "${RTT_ms} ms"
printf "    - %-12s : %s\n" "计算BDP" "${BDP_MB} MB"
printf "    - %-12s : %s\n" "最终缓冲区" "${MAX_MB} MB"
echo

# II. 内核参数验证
echo -e "${GREEN}[+] II. 内核参数验证${RESET}"
printf "    - %-25s : %s\n" "TCP 拥塞控制" "$(sysctl -n net.ipv4.tcp_congestion_control)"
printf "    - %-25s : %s\n" "默认包调度器" "$(sysctl -n net.core.default_qdisc)"
printf "    - %-25s : %s (%s MB)\n" "最大接收缓冲区" "$(sysctl -n net.core.rmem_max)" "$MAX_MB"
printf "    - %-25s : %s (%s MB)\n" "最大发送缓冲区" "$(sysctl -n net.core.wmem_max)" "$MAX_MB"
printf "    - %-25s : %s\n" "TCP 接收缓冲区 (min/def/max)" "$(sysctl -n net.ipv4.tcp_rmem)"
printf "    - %-25s : %s\n" "TCP 发送缓冲区 (min/def/max)" "$(sysctl -n net.ipv4.tcp_wmem)"
echo

# III. 网络接口验证
if command -v tc >/dev/null 2>&1 && [ -n "${IFACE:-}" ]; then
    echo -e "${GREEN}[+] III. 网络接口验证${RESET}"
    printf "    - 接口 %-10s : %s\n" "${IFACE} 队列" "$(tc qdisc show dev "$IFACE" | head -1)"
fi

echo "=================================="
