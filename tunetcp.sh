#!/usr/bin/env sh
set -eu

# =========================================================
# TuneTCP v2.1 - Linux TCP/UDP Network Optimization Tool
# - POSIX compliant, supports all Linux distros (including Alpine/BusyBox)
# - Optimizes both IPv4 and IPv6 (dual-stack and single-stack)
# - Supports CLI args, non-interactive mode, uninstall
# https://github.com/Michaol/tunetcp
# =========================================================

VERSION="2.1.0"
SYSCTL_TARGET="/etc/sysctl.d/999-net-bbr-fq.conf"

# --- Colors ---
GREEN='\033[1;32m'
BLUE='\033[1;34m'
YELLOW='\033[1;33m'
RED='\033[1;31m'
RESET='\033[0m'

# --- Helper functions ---
note() { printf "${BLUE}[i]${RESET} %s\n" "$*" >&2; }
ok()   { printf "${GREEN}[OK]${RESET} %s\n" "$*" >&2; }
warn() { printf "${YELLOW}[!]${RESET} %s\n" "$*" >&2; }
bad()  { printf "${RED}[!!]${RESET} %s\n" "$*" >&2; exit 1; }

# --- Default values ---
MEM_G=""
BW_Mbps=1000
RTT_ms=""
SKIP_CONFIRM=0
DO_UNINSTALL=0

# --- Help ---
show_help() {
    cat <<EOF
TuneTCP v${VERSION} - Linux TCP/UDP Network Optimization Tool

Usage: $0 [options]

Options:
  -m, --mem <GiB>     Memory size (default: auto-detect)
  -b, --bw <Mbps>     Bandwidth (default: 1000)
  -r, --rtt <ms>      RTT latency (default: auto-detect)
  -y, --yes           Skip confirmation, apply directly
  --uninstall         Uninstall and restore defaults
  -h, --help          Show this help
  -v, --version       Show version

Examples:
  $0                  # Interactive mode
  $0 -b 500 -r 50 -y  # Non-interactive mode
  $0 --uninstall      # Uninstall
EOF
    exit 0
}

show_version() {
    echo "TuneTCP v${VERSION}"
    exit 0
}

# --- Auto-detect functions ---
get_mem_gib() {
    mem_kib=$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)
    awk -v kib="$mem_kib" 'BEGIN {printf "%.2f", kib / 1024 / 1024}'
}

get_rtt_ms() {
    ping_target=""
    ping_desc=""

    if [ -n "${SSH_CONNECTION-}" ]; then
        ping_target=$(echo "$SSH_CONNECTION" | awk '{print $1}')
        ping_desc="SSH client ${ping_target}"
        note "Auto-detected SSH client IP: ${ping_target}"
    elif [ "$SKIP_CONFIRM" != "1" ]; then
        note "No SSH connection detected, please provide a client IP."
        printf "Enter client IP for ping test (press Enter for 1.1.1.1): "
        read -r client_ip </dev/tty 2>/dev/null || client_ip=""
        if [ -n "$client_ip" ]; then
            ping_target="$client_ip"
            ping_desc="Client IP ${ping_target}"
        fi
    fi
    
    if [ -z "$ping_target" ]; then
        ping_target="1.1.1.1"
        ping_desc="Public address ${ping_target}"
        note "Using ${ping_desc} for RTT test."
    fi

    note "Testing network latency via ping ${ping_desc}..."
    ping_result=$(ping -c 4 -W 2 "$ping_target" 2>/dev/null | tail -1 | awk -F'/' '{print $5}')
    
    is_ping_num=$(echo "$ping_result" | awk '/^[0-9]+([.][0-9]+)?$/ {print 1}')
    if [ "$is_ping_num" = "1" ]; then
        ok "Detected average RTT: ${ping_result} ms"
        echo "$ping_result" | awk '{printf "%.0f\n", $1}'
    else
        warn "Ping ${ping_target} failed. Using default 150 ms."
        echo "150"
    fi
}

# --- BusyBox compatible sysctl apply ---
apply_sysctl_settings() {
    note "Applying sysctl configuration..."
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
        # shellcheck disable=SC2086
        sysctl -e -p $files_to_load >/dev/null 2>&1 || true
    fi
}

# --- Validation ---
is_num() { echo "$1" | awk '/^[0-9]+([.][0-9]+)?$/ {print 1}'; }
is_int() { echo "$1" | awk '/^[0-9]+$/ {print 1}'; }

validate_params() {
    mem_valid=$(awk -v m="$MEM_G" 'BEGIN { print (m >= 0.1 && m <= 1024) ? 1 : 0 }')
    if [ "$mem_valid" != "1" ]; then
        bad "Memory out of range (0.1-1024 GiB): $MEM_G"
    fi
    
    if [ "$BW_Mbps" -lt 1 ] || [ "$BW_Mbps" -gt 100000 ]; then
        bad "Bandwidth out of range (1-100000 Mbps): $BW_Mbps"
    fi
    
    rtt_valid=$(awk -v r="$RTT_ms" 'BEGIN { print (r >= 1 && r <= 10000) ? 1 : 0 }')
    if [ "$rtt_valid" != "1" ]; then
        bad "RTT out of range (1-10000 ms): $RTT_ms"
    fi
}

# --- Core functions ---
require_root() { 
    if [ "$(id -u)" -ne 0 ]; then 
        bad "Please run as root"
    fi
}

default_iface() {
    iface=$(ip -o -4 route show to default 2>/dev/null | awk '{print $5}' | head -1)
    if [ -z "$iface" ]; then
        iface=$(ip -o -6 route show to default 2>/dev/null | awk '{print $5}' | head -1)
    fi
    echo "$iface"
}

KEY_REGEX='^net\.core\.default_qdisc|^net\.core\.rmem_max|^net\.core\.wmem_max|^net\.core\.rmem_default|^net\.core\.wmem_default|^net\.ipv4\.tcp_rmem|^net\.ipv4\.tcp_wmem|^net\.ipv4\.tcp_congestion_control|^net\.ipv4\.tcp_slow_start_after_idle|^net\.ipv4\.tcp_notsent_lowat|^net\.core\.somaxconn|^net\.ipv4\.tcp_max_syn_backlog|^net\.core\.netdev_max_backlog|^net\.ipv4\.ip_local_port_range|^net\.ipv4\.udp_rmem_min|^net\.ipv4\.udp_wmem_min|^net\.core\.optmem_max|^net\.ipv4\.tcp_fastopen|^net\.ipv4\.tcp_fin_timeout|^net\.ipv4\.tcp_tw_reuse|^net\.ipv4\.tcp_keepalive|^net\.ipv4\.tcp_syncookies|^net\.ipv4\.tcp_max_tw_buckets|^net\.ipv4\.tcp_window_scaling|^net\.ipv4\.tcp_timestamps|^net\.ipv4\.tcp_sack'

# --- Uninstall ---
do_uninstall() {
    require_root
    note "Uninstalling TuneTCP configuration..."
    
    if [ -f "$SYSCTL_TARGET" ]; then
        rm -f "$SYSCTL_TARGET"
        ok "Removed config file: $SYSCTL_TARGET"
    else
        note "Config file does not exist, nothing to remove"
    fi
    
    apply_sysctl_settings 2>/dev/null || true
    
    iface=$(default_iface)
    if command -v tc >/dev/null 2>&1 && [ -n "${iface-}" ]; then
        tc qdisc replace dev "$iface" root pfifo_fast 2>/dev/null || true
        note "Attempted to restore default qdisc for $iface"
    fi
    
    ok "TuneTCP configuration uninstalled"
    exit 0
}

# --- Conflict cleanup ---
comment_conflicts_in_sysctl_conf() {
    f="/etc/sysctl.conf"
    [ -f "$f" ] || { ok "/etc/sysctl.conf does not exist"; return 0; }
    if grep -E "$KEY_REGEX" "$f" >/dev/null; then
        backup_file="${f}.bak.$(date +%Y%m%d-%H%M%S)"
        note "Found conflicts, backing up to ${backup_file}"
        cp -a "$f" "$backup_file"
        
        note "Commenting out conflicting keys in /etc/sysctl.conf"
        sed_script=""
        for key in $(echo "$KEY_REGEX" | tr '|' ' '); do
            clean_key="${key#^}"
            sed_script="${sed_script}s/^[[:space:]]*${clean_key}/# &/;"
        done
        sed "$sed_script" "$f" > "${f}.tmp" && mv "${f}.tmp" "$f"
        ok "Commented out conflicting keys"
    else
        ok "/etc/sysctl.conf has no conflicts"
    fi
}

delete_conflict_files_in_dir() {
    dir="$1"
    [ -d "$dir" ] || { ok "$dir does not exist"; return 0; }
    moved=0
    backup_suffix=".bak.$(date +%Y%m%d-%H%M%S)"
    for f in "$dir"/*.conf; do
        [ -e "$f" ] || [ -L "$f" ] || continue
        [ "$(readlink -f "$f")" = "$(readlink -f "$SYSCTL_TARGET")" ] && continue
        if grep -E "$KEY_REGEX" "$f" >/dev/null; then
            backup_file="${f}${backup_suffix}"
            mv -- "$f" "$backup_file"
            note "Backed up and removed: $f -> $backup_file"
            moved=1
        fi
    done
    if [ "$moved" -eq 1 ]; then 
        ok "$dir conflicts handled"
    else 
        ok "$dir no conflicts"
    fi
}

scan_conflicts_ro() {
    dir="$1"
    [ -d "$dir" ] || { ok "$dir does not exist"; return 0; }
    if grep -rE "$KEY_REGEX" "$dir" >/dev/null 2>&1; then
        warn "Found potential conflicts (read-only): $dir"
        grep -rnhE "$KEY_REGEX" "$dir" 2>/dev/null || true
    else
        ok "$dir no conflicts"
    fi
}

# --- Dynamic bucket functions ---
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

# Dynamic somaxconn based on memory
get_somaxconn() {
    mem_int=$(printf "%.0f" "$MEM_G")
    if [ "$mem_int" -ge 8 ]; then echo 65535
    elif [ "$mem_int" -ge 4 ]; then echo 32768
    elif [ "$mem_int" -ge 2 ]; then echo 16384
    else echo 8192
    fi
}

# Dynamic netdev_max_backlog based on bandwidth
get_netdev_backlog() {
    if [ "$BW_Mbps" -ge 10000 ]; then echo 65535
    elif [ "$BW_Mbps" -ge 1000 ]; then echo 32768
    elif [ "$BW_Mbps" -ge 100 ]; then echo 16384
    else echo 8192
    fi
}

# ---- Parse CLI args ----
while [ $# -gt 0 ]; do
    case "$1" in
        -m|--mem)
            MEM_G="$2"
            shift 2
            ;;
        -b|--bw)
            BW_Mbps="$2"
            shift 2
            ;;
        -r|--rtt)
            RTT_ms="$2"
            shift 2
            ;;
        -y|--yes)
            SKIP_CONFIRM=1
            shift
            ;;
        --uninstall)
            DO_UNINSTALL=1
            shift
            ;;
        -h|--help)
            show_help
            ;;
        -v|--version)
            show_version
            ;;
        *)
            bad "Unknown option: $1 (use -h for help)"
            ;;
    esac
done

# Handle uninstall
if [ "$DO_UNINSTALL" = "1" ]; then
    do_uninstall
fi

# Auto-detect if not specified
[ -z "$MEM_G" ] && MEM_G=$(get_mem_gib)
[ -z "$RTT_ms" ] && RTT_ms=$(get_rtt_ms)

# --- Interactive confirmation loop ---
if [ "$SKIP_CONFIRM" != "1" ]; then
    while true; do
        command -v clear >/dev/null && clear
        note "Please check and confirm the following parameters:"
        printf %s\\n "--------------------------------------------------"
        printf "1. Memory      : %s GiB (auto-detected)\n" "$MEM_G"
        printf "2. Bandwidth   : %s Mbps (please modify if needed)\n" "$BW_Mbps"
        printf "3. RTT Latency : %s ms (auto-detected)\n" "$RTT_ms"
        printf %s\\n "--------------------------------------------------"
        printf "Press [Enter] to apply, [1-3] to modify, [q] to quit: "
        read -r choice </dev/tty

        case "$choice" in
            "")
                note "Parameters confirmed, starting optimization..."
                break
                ;;
            1)
                printf "Enter new memory size (GiB) [%s]: " "$MEM_G"
                read -r new_mem </dev/tty
                MEM_G="${new_mem:-$MEM_G}"
                ;;
            2)
                printf "Enter bandwidth (Mbps) [%s]: " "$BW_Mbps"
                read -r new_bw </dev/tty
                BW_Mbps="${new_bw:-$BW_Mbps}"
                ;;
            3)
                printf "Enter RTT latency (ms) [%s]: " "$RTT_ms"
                read -r new_rtt </dev/tty
                RTT_ms="${new_rtt:-$RTT_ms}"
                ;;
            q|Q)
                note "User cancelled."
                exit 0
                ;;
            *)
                warn "Invalid input, please try again."
                sleep 1
                ;;
        esac
    done
fi

# --- Validation ---
if [ ! "$(is_num "$MEM_G")" = "1" ] || [ ! "$(is_int "$BW_Mbps")" = "1" ] || [ ! "$(is_num "$RTT_ms")" = "1" ]; then
    bad "Parameters contain invalid non-numeric input."
fi
validate_params

require_root

# ---- Calculate buffer sizes based on BDP ----
BDP_BYTES=$(awk -v bw="$BW_Mbps" -v rtt="$RTT_ms" 'BEGIN{ printf "%.0f", bw*125*rtt }')
MEM_BYTES=$(awk -v g="$MEM_G" 'BEGIN{ printf "%.0f", g*1024*1024*1024 }')
TWO_BDP=$(( BDP_BYTES*2 ))
RAM3_BYTES=$(awk -v m="$MEM_BYTES" 'BEGIN{ printf "%.0f", m*0.03 }')
CAP64=$(( 64*1024*1024 ))
MAX_NUM_BYTES=$(awk -v a="$TWO_BDP" -v b="$RAM3_BYTES" -v c="$CAP64" 'BEGIN{ m=a; if(b<m)m=b; if(c<m)m=c; printf "%.0f", m }')

MAX_MB_NUM=$(( MAX_NUM_BYTES/1024/1024 ))
MAX_MB=$(bucket_le_mb "$MAX_MB_NUM")
MAX_BYTES=$(( MAX_MB*1024*1024 ))

# Dynamic default buffer sizes based on memory
if [ "$MAX_MB" -ge 32 ]; then
    DEF_R=262144; DEF_W=524288
elif [ "$MAX_MB" -ge 8 ]; then
    DEF_R=131072; DEF_W=262144
else
    DEF_R=131072; DEF_W=131072
fi

# TCP buffer min/default/max
TCP_RMEM_MIN=4096; TCP_RMEM_DEF=131072; TCP_RMEM_MAX=$MAX_BYTES
TCP_WMEM_MIN=4096; TCP_WMEM_DEF=131072; TCP_WMEM_MAX=$MAX_BYTES

# Dynamic queue sizes
SOMAXCONN=$(get_somaxconn)
NETDEV_BACKLOG=$(get_netdev_backlog)

# ---- Cleanup conflicts ----
note "Step A: Backup and comment /etc/sysctl.conf conflicts"
comment_conflicts_in_sysctl_conf

note "Step B: Backup and remove conflicting files in /etc/sysctl.d"
delete_conflict_files_in_dir "/etc/sysctl.d"

note "Step C: Scan other directories (read-only)"
scan_conflicts_ro "/usr/local/lib/sysctl.d"
scan_conflicts_ro "/usr/lib/sysctl.d"
scan_conflicts_ro "/lib/sysctl.d"
scan_conflicts_ro "/run/sysctl.d"

# ---- Enable BBR module ----
if command -v modprobe >/dev/null 2>&1; then 
    modprobe tcp_bbr 2>/dev/null || true
fi

# ---- Write and apply ----
tmpf="$(mktemp)"
trap 'rm -f "$tmpf"' EXIT INT TERM

BDP_MB_display=$(awk -v b="$BDP_BYTES" 'BEGIN{ printf "%.2f", b/1024/1024 }')

cat > "$tmpf" << SYSCTL_EOF
# =============================================================================
# Auto-generated by TuneTCP v${VERSION} (https://github.com/Michaol/tunetcp)
# Optimized for: IPv4 + IPv6, TCP + UDP (dual-stack compatible)
# =============================================================================
# Inputs: MEM_G=${MEM_G}GiB, BW=${BW_Mbps}Mbps, RTT=${RTT_ms}ms
# BDP: ${BDP_BYTES} bytes (~${BDP_MB_display} MB)
# Caps: min(2*BDP, 3%RAM, 64MB) -> Bucket ${MAX_MB} MB

# -----------------------------------------------------------------------------
# Congestion Control & Queue Discipline
# -----------------------------------------------------------------------------
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# -----------------------------------------------------------------------------
# Core Buffer Sizes (applies to both IPv4 and IPv6)
# -----------------------------------------------------------------------------
net.core.rmem_default = ${DEF_R}
net.core.wmem_default = ${DEF_W}
net.core.rmem_max = ${MAX_BYTES}
net.core.wmem_max = ${MAX_BYTES}
net.core.optmem_max = 65536

# -----------------------------------------------------------------------------
# TCP Buffer Sizes (shared by IPv4 and IPv6 TCP stack)
# Format: min default max
# -----------------------------------------------------------------------------
net.ipv4.tcp_rmem = ${TCP_RMEM_MIN} ${TCP_RMEM_DEF} ${TCP_RMEM_MAX}
net.ipv4.tcp_wmem = ${TCP_WMEM_MIN} ${TCP_WMEM_DEF} ${TCP_WMEM_MAX}

# -----------------------------------------------------------------------------
# TCP Performance Tuning
# -----------------------------------------------------------------------------
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_notsent_lowat = 16384
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_sack = 1

# -----------------------------------------------------------------------------
# Connection Queue Sizes (dynamic based on memory/bandwidth)
# -----------------------------------------------------------------------------
net.core.somaxconn = ${SOMAXCONN}
net.ipv4.tcp_max_syn_backlog = ${SOMAXCONN}
net.core.netdev_max_backlog = ${NETDEV_BACKLOG}

# -----------------------------------------------------------------------------
# TCP Keepalive & Timeout Settings
# -----------------------------------------------------------------------------
net.ipv4.tcp_keepalive_time = 600
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 3
net.ipv4.tcp_fin_timeout = 15

# -----------------------------------------------------------------------------
# TCP Connection Reuse & Security
# -----------------------------------------------------------------------------
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_max_tw_buckets = 65535
net.ipv4.tcp_syncookies = 1

# -----------------------------------------------------------------------------
# Port Range & UDP Settings
# -----------------------------------------------------------------------------
net.ipv4.ip_local_port_range = 1024 65535
net.ipv4.udp_rmem_min = 8192
net.ipv4.udp_wmem_min = 8192
SYSCTL_EOF

install -m 0644 "$tmpf" "$SYSCTL_TARGET"

# Apply configuration
apply_sysctl_settings

IFACE="$(default_iface)"
if command -v tc >/dev/null 2>&1 && [ -n "${IFACE-}" ]; then
    note "Setting fq qdisc for interface ${IFACE}..."
    tc qdisc replace dev "$IFACE" root fq 2>/dev/null || true
fi

# ---- Verify critical params ----
current_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "unknown")
if [ "$current_cc" != "bbr" ]; then
    warn "BBR not enabled (current: $current_cc), please check kernel support"
fi

# ---- Output results ----
ok "TCP/UDP optimization applied successfully!"
echo
echo "==== [ TuneTCP v${VERSION} Results ] ===="
echo

BDP_MB=$(awk -v b="$BDP_BYTES" 'BEGIN{ printf "%.2f", b/1024/1024 }')

printf '%b[+] I. Input Parameters%b\n' "$GREEN" "$RESET"
printf "    - %-12s : %s\n" "Memory" "${MEM_G} GiB"
printf "    - %-12s : %s\n" "Bandwidth" "${BW_Mbps} Mbps"
printf "    - %-12s : %s\n" "RTT" "${RTT_ms} ms"
printf "    - %-12s : %s\n" "BDP" "${BDP_MB} MB"
printf "    - %-12s : %s\n" "Buffer Max" "${MAX_MB} MB"
echo

printf '%b[+] II. Dynamic Parameters%b\n' "$GREEN" "$RESET"
printf "    - %-25s : %s\n" "somaxconn" "${SOMAXCONN}"
printf "    - %-25s : %s\n" "tcp_max_syn_backlog" "${SOMAXCONN}"
printf "    - %-25s : %s\n" "netdev_max_backlog" "${NETDEV_BACKLOG}"
echo

printf '%b[+] III. Kernel Verification%b\n' "$GREEN" "$RESET"
printf "    - %-25s : %s\n" "TCP Congestion Control" "$(sysctl -n net.ipv4.tcp_congestion_control)"
printf "    - %-25s : %s\n" "Default Qdisc" "$(sysctl -n net.core.default_qdisc)"
printf "    - %-25s : %s (%s MB)\n" "Max Recv Buffer" "$(sysctl -n net.core.rmem_max)" "$MAX_MB"
printf "    - %-25s : %s (%s MB)\n" "Max Send Buffer" "$(sysctl -n net.core.wmem_max)" "$MAX_MB"
printf "    - %-25s : %s\n" "TCP rmem (min/def/max)" "$(sysctl -n net.ipv4.tcp_rmem)"
printf "    - %-25s : %s\n" "TCP wmem (min/def/max)" "$(sysctl -n net.ipv4.tcp_wmem)"
printf "    - %-25s : %s\n" "TCP Window Scaling" "$(sysctl -n net.ipv4.tcp_window_scaling)"
printf "    - %-25s : %s\n" "TCP Timestamps" "$(sysctl -n net.ipv4.tcp_timestamps)"
printf "    - %-25s : %s\n" "TCP SACK" "$(sysctl -n net.ipv4.tcp_sack)"
printf "    - %-25s : %s\n" "TCP SYN Cookies" "$(sysctl -n net.ipv4.tcp_syncookies)"
echo

if command -v tc >/dev/null 2>&1 && [ -n "${IFACE-}" ]; then
    printf '%b[+] IV. Network Interface%b\n' "$GREEN" "$RESET"
    printf "    - Interface %-10s : %s\n" "${IFACE}" "$(tc qdisc show dev "$IFACE" | head -1)"
fi

echo "=========================================="
echo
note "Config file: $SYSCTL_TARGET"
note "Uninstall: $0 --uninstall"
