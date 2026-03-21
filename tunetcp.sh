#!/usr/bin/env bash
set -eu
set -o pipefail 2>/dev/null || true

# =========================================================
# TuneTCP v2.5 - Linux TCP/UDP Network Optimization Tool
# - POSIX compliant, supports all Linux distros (including Alpine/BusyBox)
# - Optimizes both IPv4 and IPv6 (dual-stack and single-stack)
# - BBRv2 support, memory tiering, enhanced RTT detection
# - Proxy/VPN optimized (RPS/XPS, conntrack, ECN, thin stream)
# https://github.com/Michaol/tunetcp
# =========================================================

VERSION="2.5.0"
SYSCTL_TARGET="/etc/sysctl.d/999-net-bbr-fq.conf"

# --- Colors ---
GREEN='\033[1;32m'
BLUE='\033[1;34m'
YELLOW='\033[1;33m'
RED='\033[1;31m'
RESET='\033[0m'

# --- TTY & Color support ---
check_tty() {
    # If stdout is not a terminal, disable colors
    if [ ! -t 1 ]; then
        GREEN=''
        BLUE=''
        YELLOW=''
        RED=''
        RESET=''
    fi
}
check_tty

# --- Global cache variables ---
MEM_BYTES=""
BDP_BYTES=""
INTERFACE=""
CPU_CORES=""
HAS_BBR2=0
RPS_CONFIGURED=0
CONNTRACK_AVAILABLE=0
MEM_TIER=""
RTT_JITTER=""
RTT_LOSS=""
RTT_TARGET=""

# --- Helper functions ---
note() { printf "${BLUE}[i]${RESET} %s\n" "$*" >&2; }
ok()   { printf "${GREEN}[OK]${RESET} %s\n" "$*" >&2; }
warn() { printf "${YELLOW}[!]${RESET} %s\n" "$*" >&2; }
bad()  { printf "${RED}[!!]${RESET} %s\n" "$*" >&2; exit 1; }
debug() { 
    if [ "${DEBUG:-0}" = "1" ]; then
        printf "${BLUE}[DEBUG]${RESET} %s\n" "$*" >&2
    fi
}

# --- Default values ---
MEM_G=""
BW_Mbps=1000
RTT_ms=""
SKIP_CONFIRM=0
DO_UNINSTALL=0
DRY_RUN=0

# --- Input validation ---
sanitize_input() {
    # POSIX compliant way to remove non-numeric characters except dot
    echo "$1" | tr -cd '0-9.'
}

is_num() { 
    echo "$1" | awk '/^[0-9]+([.][0-9]+)?$/ {print 1}' 
}

is_int() { 
    echo "$1" | awk '/^[0-9]+$/ {print 1}' 
}

# --- System requirements check ---
check_requirements() {
    local missing_tools=""
    
    # Check essential tools
    for tool in awk sed sysctl ip; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            missing_tools="${missing_tools}${tool} "
        fi
    done
    
    if [ -n "$missing_tools" ]; then
        bad "Missing required tools: ${missing_tools}"
    fi
    
    # Check sysctl.d directory
    if [ ! -d "/etc/sysctl.d" ]; then
        note "/etc/sysctl.d doesn't exist, creating..."
        mkdir -p /etc/sysctl.d || bad "Cannot create config directory"
    fi
    
    debug "System requirements check passed"
}

# --- Detection functions ---
check_bbr2_support() {
    if command -v modprobe >/dev/null 2>&1; then
        modprobe tcp_bbr2 2>/dev/null || true
    fi
    if grep -q bbr2 /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null; then
        HAS_BBR2=1
        ok "BBRv2 supported and loaded"
    else
        HAS_BBR2=0
        note "BBRv2 not available, will use BBRv1"
    fi
}

get_cpu_cores() {
    CPU_CORES=$(nproc 2>/dev/null || grep -c ^processor /proc/cpuinfo 2>/dev/null || echo 1)
    debug "CPU cores: $CPU_CORES"
}

check_conntrack_module() {
    if [ -d /proc/sys/net/netfilter ]; then
        CONNTRACK_AVAILABLE=1
        debug "conntrack available"
    elif modprobe nf_conntrack 2>/dev/null && [ -d /proc/sys/net/netfilter ]; then
        CONNTRACK_AVAILABLE=1
        debug "conntrack module loaded"
    else
        CONNTRACK_AVAILABLE=0
        warn "conntrack not available, skipping conntrack optimization"
    fi
}

get_mem_tier() {
    local mem_g="$1"
    if awk -v m="$mem_g" 'BEGIN { exit (m < 1) ? 0 : 1 }'; then
        MEM_TIER="low"
    elif awk -v m="$mem_g" 'BEGIN { exit (m < 4) ? 0 : 1 }'; then
        MEM_TIER="medium"
    else
        MEM_TIER="high"
    fi
    debug "Memory tier: $MEM_TIER (${mem_g} GiB)"
}

# --- Kernel version check ---
check_kernel() {
    local kernel_ver=$(uname -r | cut -d'-' -f1)
    note "Current kernel version: ${kernel_ver}"
    
    # BBR requires Linux 4.9+
    local major=$(echo "$kernel_ver" | cut -d'.' -f1)
    local minor=$(echo "$kernel_ver" | cut -d'.' -f2)
    
    if [ "$major" -lt 4 ] || { [ "$major" -eq 4 ] && [ "$minor" -lt 9 ]; }; then
        warn "Kernel version ${kernel_ver} is too old for BBR (requires 4.9+)."
        warn "BBR settings will be skipped."
        return 1
    fi

    # Check BBRv2 support (requires 5.8+)
    if [ "$major" -gt 5 ] || { [ "$major" -eq 5 ] && [ "$minor" -ge 8 ]; }; then
        check_bbr2_support
    else
        HAS_BBR2=0
        note "Kernel < 5.8, BBRv2 not available, using BBRv1"
    fi

    return 0
}

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
  --dry-run           Show what would be done without making changes
  -h, --help          Show this help
  -v, --version       Show version
  -d, --debug         Enable debug mode

Examples:
  $0                  # Interactive mode
  $0 -b 500 -r 50 -y  # Non-interactive mode
  $0 --uninstall      # Uninstall
  $0 --dry-run        # Preview changes
  $0 -d -b 1000 -y    # Debug mode with auto-apply
EOF
    exit 0
}

show_version() {
    echo "TuneTCP v${VERSION}"
    exit 0
}

# --- Auto-detect functions ---
get_mem_gib() {
    if [ -n "${MEM_BYTES:-}" ]; then
        awk -v bytes="$MEM_BYTES" 'BEGIN {printf "%.2f", bytes / 1024 / 1024 / 1024}'
        return
    fi
    
    if [ ! -f "/proc/meminfo" ]; then
        warn "Cannot read /proc/meminfo, using default 1 GiB"
        echo "1"
        return
    fi
    
    mem_kib=$(awk '/^MemTotal:/ {print $2}' /proc/meminfo 2>/dev/null)
    if [ -z "$mem_kib" ] || [ "$mem_kib" -le 0 ]; then
        warn "Failed to detect memory, using default 1 GiB"
        echo "1"
        return
    fi
    
    awk -v kib="$mem_kib" 'BEGIN {printf "%.2f", kib / 1024 / 1024}'
}

get_mem_bytes() {
    if [ -z "${MEM_BYTES:-}" ]; then
        local mem_g="$1"
        MEM_BYTES=$(awk -v g="$mem_g" 'BEGIN{ printf "%.0f", g*1024*1024*1024 }')
    fi
    echo "$MEM_BYTES"
}

get_rtt_ms() {
    local ping_target=""
    local ping_desc=""

    # 1. Priority: SSH client IP
    if [ -n "${SSH_CONNECTION-}" ]; then
        ping_target=$(echo "$SSH_CONNECTION" | awk '{print $1}')
        ping_desc="SSH client ${ping_target}"
        note "Auto-detected SSH client IP: ${ping_target}"
    fi

    # 2. Interactive mode: user input
    if [ -z "$ping_target" ] && [ "$SKIP_CONFIRM" != "1" ]; then
        note "No SSH connection detected."
        printf "Enter client IP for ping test: " </dev/tty
        read -r client_ip </dev/tty || client_ip=""
        if [ -n "$client_ip" ]; then
            ping_target="$client_ip"
            ping_desc="Client IP ${ping_target}"
        fi
    fi

    # 3. Fallback: public DNS (if still no target)
    if [ -z "$ping_target" ]; then
        note "Trying fallback public DNS targets..."
        for fallback in 1.1.1.1 8.8.8.8 223.5.5.5; do
            if ping -c 1 -W 2 "$fallback" >/dev/null 2>&1; then
                ping_target="$fallback"
                ping_desc="Public DNS ${ping_target}"
                note "Fallback target: ${ping_target}"
                break
            fi
        done
    fi

    # 4. All targets failed
    if [ -z "$ping_target" ]; then
        warn "All ping targets failed, using default 150 ms"
        echo "150"
        return
    fi

    # 5. Check ping availability
    if ! command -v ping >/dev/null 2>&1; then
        warn "ping command not available, using default 150 ms"
        echo "150"
        return
    fi

    # 6. Execute ping test (10 packets)
    note "Testing latency to ${ping_desc} (10 packets)..."
    local ping_output
    ping_output=$(ping -c 10 -W 3 "$ping_target" 2>/dev/null)

    if [ $? -ne 0 ] || [ -z "$ping_output" ]; then
        warn "Ping to ${ping_target} failed, using default 150 ms"
        echo "150"
        return
    fi

    # 7. Parse packet loss
    RTT_LOSS=$(echo "$ping_output" | grep -oP '\d+(?=% packet loss)' || echo "0")
    [ -z "$RTT_LOSS" ] && RTT_LOSS="0"

    # 8. Parse RTT stats (min/avg/max/mdev)
    local rtt_stats
    rtt_stats=$(echo "$ping_output" | grep -oP 'rtt min/avg/max/mdev = \K[\d./]+' || echo "")

    if [ -z "$rtt_stats" ]; then
        warn "Failed to parse ping stats, using default 150 ms"
        echo "150"
        return
    fi

    local rtt_min rtt_avg rtt_max rtt_mdev
    IFS='/' read -r rtt_min rtt_avg rtt_max rtt_mdev <<< "$rtt_stats"

    RTT_JITTER="$rtt_mdev"
    RTT_TARGET="$ping_target"

    ok "RTT: ${rtt_avg} ms, Jitter: ${rtt_mdev} ms, Loss: ${RTT_LOSS}%"

    # Return rounded average
    echo "$rtt_avg" | awk '{printf "%.0f\n", $1}'
}

# --- BusyBox compatible sysctl apply ---
apply_sysctl_settings() {
    if [ "$DRY_RUN" = "1" ]; then
        note "Dry-run mode: Skipping sysctl application."
        return 0
    fi
    
    note "Applying sysctl configuration..."
    
    # Try sysctl --system first (modern standard)
    if sysctl --system >/dev/null 2>&1; then
        ok "Applied sysctl settings via --system"
        return 0
    fi
    
    # Fallback to manual scanning
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
        # Apply configuration with error handling
        if ! sysctl -e -p $files_to_load >/dev/null 2>&1; then
            warn "sysctl apply failed, trying individual files..."
            for file in $files_to_load; do
                if [ -f "$file" ]; then
                    if ! sysctl -e -p "$file" >/dev/null 2>&1; then
                        warn "Failed to apply: $file"
                    else
                        debug "Applied: $file"
                    fi
                fi
            done
        fi
    fi
}

# --- Validation ---
validate_params() {
    # Memory validation
    mem_valid=$(awk -v m="$MEM_G" 'BEGIN { print (m >= 0.1 && m <= 1024) ? 1 : 0 }')
    if [ "$mem_valid" != "1" ]; then
        bad "Memory out of range (0.1-1024 GiB): $MEM_G"
    fi
    
    # Bandwidth validation
    if [ "$BW_Mbps" -lt 1 ] || [ "$BW_Mbps" -gt 100000 ]; then
        bad "Bandwidth out of range (1-100000 Mbps): $BW_Mbps"
    fi
    
    # RTT validation
    rtt_valid=$(awk -v r="$RTT_ms" 'BEGIN { print (r >= 1 && r <= 10000) ? 1 : 0 }')
    if [ "$rtt_valid" != "1" ]; then
        bad "RTT out of range (1-10000 ms): $RTT_ms"
    fi
    
    debug "Parameter validation passed: MEM_G=$MEM_G, BW=$BW_Mbps, RTT=$RTT_ms"
}

# --- Core functions ---
require_root() { 
    if [ "$(id -u)" -ne 0 ]; then 
        bad "Please run as root (current UID: $(id -u))"
    fi
    debug "Root privilege confirmed"
}

default_iface() {
    if [ -n "${INTERFACE:-}" ]; then
        echo "$INTERFACE"
        return
    fi
    
    # Try IPv4 first, then IPv6, exclude lo and docker
    iface=$(ip -o -4 route show to default 2>/dev/null | grep -vE "docker|lo" | awk '{print $5}' | head -1)
    if [ -z "$iface" ]; then
        iface=$(ip -o -6 route show to default 2>/dev/null | grep -vE "docker|lo" | awk '{print $5}' | head -1)
    fi
    
    # Fallback to current up interfaces
    if [ -z "$iface" ]; then
        iface=$(ip -o link show | grep "UP" | grep -vE "lo|docker" | awk -F': ' '{print $2}' | head -1)
    fi
    
    if [ -z "$iface" ]; then
        warn "Could not detect default interface"
        INTERFACE=""
    else
        INTERFACE="$iface"
        debug "Detected interface: $iface"
    fi
    
    echo "$iface"
}

# --- Key definitions ---
# List of sysctl keys we manage
SYSCTL_KEYS="net.core.default_qdisc \
net.core.rmem_max \
net.core.wmem_max \
net.core.rmem_default \
net.core.wmem_default \
net.core.optmem_max \
net.core.somaxconn \
net.core.netdev_max_backlog \
net.core.netdev_budget \
net.core.netdev_budget_usecs \
net.ipv4.tcp_rmem \
net.ipv4.tcp_wmem \
net.ipv4.tcp_congestion_control \
net.ipv4.tcp_slow_start_after_idle \
net.ipv4.tcp_notsent_lowat \
net.ipv4.tcp_moderate_rcvbuf \
net.ipv4.tcp_max_syn_backlog \
net.ipv4.tcp_fastopen \
net.ipv4.tcp_fastopen_connect \
net.ipv4.tcp_fin_timeout \
net.ipv4.tcp_tw_reuse \
net.ipv4.tcp_keepalive_time \
net.ipv4.tcp_keepalive_intvl \
net.ipv4.tcp_keepalive_probes \
net.ipv4.tcp_syncookies \
net.ipv4.tcp_max_tw_buckets \
net.ipv4.tcp_window_scaling \
net.ipv4.tcp_timestamps \
net.ipv4.tcp_sack \
net.ipv4.tcp_mtu_probing \
net.ipv4.tcp_retries1 \
net.ipv4.tcp_retries2 \
net.ipv4.tcp_syn_retries \
net.ipv4.tcp_synack_retries \
net.ipv4.tcp_abort_on_overflow \
net.ipv4.tcp_ecn \
net.ipv4.tcp_ecn_fallback \
net.ipv4.tcp_thin_linear_timeouts \
net.ipv4.tcp_thin_dupack \
net.ipv4.ip_local_port_range \
net.ipv4.udp_rmem_min \
net.ipv4.udp_wmem_min \
net.ipv4.udp_mem \
fs.file-max \
vm.swappiness \
vm.dirty_ratio \
vm.dirty_background_ratio"

# Function to build regex from keys
get_key_regex() {
    local regex=""
    for key in $SYSCTL_KEYS; do
        # Escape dots for regex
        local escaped_key=$(echo "$key" | sed 's/\./\\./g')
        if [ -z "$regex" ]; then
            regex="^${escaped_key}"
        else
            regex="${regex}|^${escaped_key}"
        fi
    done
    echo "$regex"
}

# Initial KEY_REGEX (will be used by cleanup functions)
KEY_REGEX=$(get_key_regex)

# --- Uninstall ---
do_uninstall() {
    require_root
    note "Uninstalling TuneTCP configuration..."
    
    if [ -f "$SYSCTL_TARGET" ]; then
        rm -f "$SYSCTL_TARGET" || bad "Failed to remove config file"
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
backup_file() {
    local file="$1"
    local backup_suffix=".bak.$(date +%Y%m%d-%H%M%S)"
    local backup_file="${file}${backup_suffix}"
    
    cp -a "$file" "$backup_file" || bad "Failed to backup $file"
    echo "$backup_file"
}

comment_conflicts_in_sysctl_conf() {
    local f="/etc/sysctl.conf"
    if [ ! -f "$f" ]; then
        ok "/etc/sysctl.conf does not exist"
        return 0
    fi
    
    if grep -E "$KEY_REGEX" "$f" >/dev/null; then
        local backup_file=$(backup_file "$f")
        note "Found conflicts, backed up to ${backup_file}"
        
        note "Commenting out conflicting keys in /etc/sysctl.conf"
        sed_script=""
        for key in $(echo "$KEY_REGEX" | tr '|' ' '); do
            clean_key="${key#^}"
            sed_script="${sed_script}s/^[[:space:]]*${clean_key}/# &/;"
        done
        
        if sed "$sed_script" "$f" > "${f}.tmp" && mv "${f}.tmp" "$f"; then
            ok "Commented out conflicting keys"
        else
            bad "Failed to modify /etc/sysctl.conf"
        fi
    else
        ok "/etc/sysctl.conf has no conflicts"
    fi
}

delete_conflict_files_in_dir() {
    local dir="$1"
    if [ ! -d "$dir" ]; then
        ok "$dir does not exist"
        return 0
    fi
    
    local moved=0
    local backup_suffix=".bak.$(date +%Y%m%d-%H%M%S)"
    
    for f in "$dir"/*.conf; do
        [ -e "$f" ] || [ -L "$f" ] || continue
        [ "$(readlink -f "$f" 2>/dev/null)" = "$(readlink -f "$SYSCTL_TARGET" 2>/dev/null)" ] && continue
        
        if grep -E "$KEY_REGEX" "$f" >/dev/null; then
            local backup_file="${f}${backup_suffix}"
            if mv -- "$f" "$backup_file"; then
                note "Backed up and removed: $f -> $backup_file"
                moved=1
            else
                warn "Failed to move: $f"
            fi
        fi
    done
    
    if [ "$moved" -eq 1 ]; then 
        ok "$dir conflicts handled"
    else 
        ok "$dir no conflicts"
    fi
}

scan_conflicts_ro() {
    local dir="$1"
    if [ ! -d "$dir" ]; then
        ok "$dir does not exist"
        return 0
    fi
    
    if grep -rE "$KEY_REGEX" "$dir" >/dev/null 2>&1; then
        warn "Found potential conflicts (read-only): $dir"
        grep -rnhE "$KEY_REGEX" "$dir" 2>/dev/null || true
    else
        ok "$dir no conflicts"
    fi
}

# --- RPS/XPS & Conntrack configuration ---
configure_rps_xps() {
    local iface="$1"

    # Skip for low memory or single CPU
    if [ "$MEM_TIER" = "low" ] || [ "${CPU_CORES:-1}" -le 1 ]; then
        note "Low memory or single CPU, skipping RPS/XPS"
        return 0
    fi

    if [ -z "$iface" ] || [ ! -d "/sys/class/net/$iface/queues" ]; then
        debug "Interface $iface not found or no queue support"
        return 0
    fi

    # Check if NIC has enough hardware queues
    local rx_queues=$(ls -d /sys/class/net/$iface/queues/rx-* 2>/dev/null | wc -l)
    if [ "$rx_queues" -ge "$CPU_CORES" ]; then
        note "NIC has sufficient queues ($rx_queues >= $CPU_CORES), RPS not needed"
        return 0
    fi

    note "Configuring RPS/XPS for $iface ($rx_queues queues, $CPU_CORES CPUs)..."

    # Generate CPU mask (max 8 cores)
    local mask
    if [ "$CPU_CORES" -le 4 ]; then
        mask=$(printf '%x' $((2**CPU_CORES - 1)))
    else
        mask="ff"
    fi

    # Configure RPS for each RX queue
    for rxq in /sys/class/net/$iface/queues/rx-*/rps_cpus; do
        echo "$mask" > "$rxq" 2>/dev/null || true
    done

    # Configure RFS
    local flow_entries=$((CPU_CORES * 4096))
    echo "$flow_entries" > /proc/sys/net/core/rps_sock_flow_entries 2>/dev/null || true

    if [ "$rx_queues" -gt 0 ]; then
        local flow_cnt=$((flow_entries / rx_queues))
        for rxq in /sys/class/net/$iface/queues/rx-*/rps_flow_cnt; do
            echo "$flow_cnt" > "$rxq" 2>/dev/null || true
        done
    fi

    # Configure XPS for each TX queue
    for txq in /sys/class/net/$iface/queues/tx-*/xps_cpus; do
        echo "$mask" > "$txq" 2>/dev/null || true
    done

    RPS_CONFIGURED=1
    ok "RPS/XPS configured (mask: $mask)"
}

configure_conntrack() {
    if [ "$CONNTRACK_AVAILABLE" != "1" ]; then
        return 0
    fi

    local conntrack_max
    case "$MEM_TIER" in
        low)    conntrack_max=131072 ;;
        medium) conntrack_max=524288 ;;
        high)   conntrack_max=1048576 ;;
        *)      conntrack_max=524288 ;;
    esac

    note "Configuring conntrack (max: $conntrack_max)..."

    echo "$conntrack_max" > /proc/sys/net/netfilter/nf_conntrack_max 2>/dev/null || true
    echo "86400" > /proc/sys/net/netfilter/nf_conntrack_tcp_timeout_established 2>/dev/null || true
    echo "30" > /proc/sys/net/netfilter/nf_conntrack_tcp_timeout_time_wait 2>/dev/null || true

    ok "Conntrack configured"
}

# --- Dynamic bucket functions ---
bucket_le_mb() {
    local mb="${1:-0}"
    if [ "$mb" -ge 64 ]; then echo 64
    elif [ "$mb" -ge 32 ]; then echo 32
    elif [ "$mb" -ge 16 ]; then echo 16
    elif [ "$mb" -ge 8 ]; then echo 8
    else echo 4
    fi
}

# Dynamic somaxconn based on memory tier
get_somaxconn() {
    case "$MEM_TIER" in
        low)    echo 4096 ;;
        medium) echo 32768 ;;
        high)   echo 65535 ;;
        *)      echo 32768 ;;
    esac
}

# Dynamic netdev_max_backlog based on memory tier and bandwidth
get_netdev_backlog() {
    local base
    if [ "$BW_Mbps" -ge 10000 ]; then
        base=250000
    elif [ "$BW_Mbps" -ge 1000 ]; then
        base=65535
    elif [ "$BW_Mbps" -ge 100 ]; then
        base=32768
    else
        base=10000
    fi

    # Adjust for low memory
    case "$MEM_TIER" in
        low)    echo $(( base / 5 )) ;;
        *)      echo "$base" ;;
    esac
}

# Dynamic UDP memory limits based on system memory (in pages, 1 page = 4KB)
get_udp_mem() {
    local mem_bytes="$1"
    local total_pages=$(awk -v m="$mem_bytes" 'BEGIN{ printf "%.0f", m/4096 }')
    local low_pct pressure_pct high_pct

    # Adjust percentages based on memory tier
    case "$MEM_TIER" in
        low)    low_pct=0.01; pressure_pct=0.02; high_pct=0.03 ;;
        medium) low_pct=0.03; pressure_pct=0.04; high_pct=0.06 ;;
        high)   low_pct=0.04; pressure_pct=0.05; high_pct=0.08 ;;
        *)      low_pct=0.03; pressure_pct=0.04; high_pct=0.06 ;;
    esac

    local low=$(awk -v p="$total_pages" -v pct="$low_pct" 'BEGIN{ printf "%.0f", p*pct }')
    local pressure=$(awk -v p="$total_pages" -v pct="$pressure_pct" 'BEGIN{ printf "%.0f", p*pct }')
    local high=$(awk -v p="$total_pages" -v pct="$high_pct" 'BEGIN{ printf "%.0f", p*pct }')
    echo "$low $pressure $high"
}

# Dynamic tcp_max_tw_buckets based on memory tier
get_max_tw_buckets() {
    case "$MEM_TIER" in
        low)    echo 32768 ;;
        medium) echo 131072 ;;
        high)
            local mem_mb=$(awk -v m="$MEM_G" 'BEGIN{ printf "%.0f", m*1024 }')
            local calc=$(( mem_mb * 10 ))
            # Cap at 200000
            [ "$calc" -gt 200000 ] && calc=200000
            echo "$calc"
            ;;
        *)      echo 65535 ;;
    esac
}

# --- Progress indicator ---
show_progress() {
    local step="$1"
    local total="$2"
    local message="$3"
    printf "${BLUE}[进度 %s/%s]${RESET} %s\n" "$step" "$total" "$message" >&2
}

# ---- Parse CLI args ----
while [ $# -gt 0 ]; do
    case "$1" in
        -m|--mem)
            MEM_G=$(sanitize_input "$2")
            shift 2
            ;;
        -b|--bw)
            BW_Mbps=$(sanitize_input "$2")
            shift 2
            ;;
        -r|--rtt)
            RTT_ms=$(sanitize_input "$2")
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
        --dry-run)
            DRY_RUN=1
            shift
            ;;
        -d|--debug)
            export DEBUG=1
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

# Main execution flow
main() {
    debug "Starting TuneTCP v${VERSION}"
    
    # Check requirements first
    check_requirements
    
    # Check kernel for BBR support
    HAS_BBR=1
    if ! check_kernel; then
        HAS_BBR=0
    fi

    # Additional system detection
    get_cpu_cores
    check_conntrack_module

    # Handle uninstall
    if [ "$DO_UNINSTALL" = "1" ]; then
        do_uninstall
    fi
    
    # Auto-detect if not specified
    if [ -z "$MEM_G" ]; then
        show_progress 1 5 "Detecting system memory..."
        MEM_G=$(get_mem_gib)
        debug "Auto-detected memory: ${MEM_G} GiB"
    fi

    # Determine memory tier
    get_mem_tier "$MEM_G"
    
    if [ -z "$RTT_ms" ]; then
        show_progress 2 5 "Testing network latency..."
        RTT_ms=$(get_rtt_ms)
        debug "Auto-detected RTT: ${RTT_ms} ms"
    fi
    
    # Validate inputs
    show_progress 3 5 "Validating parameters..."
    if [ ! "$(is_num "$MEM_G")" = "1" ] || [ ! "$(is_int "$BW_Mbps")" = "1" ] || [ ! "$(is_num "$RTT_ms")" = "1" ]; then
        bad "Parameters contain invalid non-numeric input."
    fi
    validate_params
    
    # Root check
    show_progress 4 5 "Checking privileges..."
    require_root
    
    # Interactive confirmation
    if [ "$SKIP_CONFIRM" != "1" ]; then
        while true; do
            command -v clear >/dev/null && clear
            note "Please check and confirm the following parameters:"
            printf %s\\n "--------------------------------------------------"
            printf "1. Memory      : %s GiB\n" "$MEM_G"
            printf "2. Bandwidth   : %s Mbps\n" "$BW_Mbps"
            printf "3. RTT Latency : %s ms\n" "$RTT_ms"
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
                    if [ -n "$new_mem" ]; then
                        MEM_G=$(sanitize_input "$new_mem")
                    fi
                    ;;
                2)
                    printf "Enter bandwidth (Mbps) [%s]: " "$BW_Mbps"
                    read -r new_bw </dev/tty
                    if [ -n "$new_bw" ]; then
                        BW_Mbps=$(sanitize_input "$new_bw")
                    fi
                    ;;
                3)
                    printf "Enter RTT latency (ms) [%s]: " "$RTT_ms"
                    read -r new_rtt </dev/tty
                    if [ -n "$new_rtt" ]; then
                        RTT_ms=$(sanitize_input "$new_rtt")
                    fi
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
    
    # Calculate parameters
    show_progress 5 5 "Calculating optimization parameters..."
    note "Calculating BDP and buffer sizes..."
    
    BDP_BYTES=$(awk -v bw="$BW_Mbps" -v rtt="$RTT_ms" 'BEGIN{ printf "%.0f", bw*125*rtt }')
    MEM_BYTES=$(get_mem_bytes "$MEM_G")
    TWO_BDP=$(( BDP_BYTES*2 ))

    # RAM percentage and cap based on memory tier
    local ram_pct cap_mb
    case "$MEM_TIER" in
        low)    ram_pct="0.02"; cap_mb=16 ;;
        *)      ram_pct="0.03"; cap_mb=64 ;;
    esac

    RAM_PCT_BYTES=$(awk -v m="$MEM_BYTES" -v p="$ram_pct" 'BEGIN{ printf "%.0f", m*p }')
    CAP_BYTES=$(( cap_mb*1024*1024 ))
    MAX_NUM_BYTES=$(awk -v a="$TWO_BDP" -v b="$RAM_PCT_BYTES" -v c="$CAP_BYTES" 'BEGIN{ m=a; if(b<m)m=b; if(c<m)m=c; printf "%.0f", m }')
    
    MAX_MB_NUM=$(( MAX_NUM_BYTES/1024/1024 ))
    MAX_MB=$(bucket_le_mb "$MAX_MB_NUM")
    MAX_BYTES=$(( MAX_MB*1024*1024 ))

    # Apply jitter adjustment (high jitter +20% buffer)
    if [ -n "$RTT_JITTER" ] && [ -n "$RTT_ms" ]; then
        if awk -v j="$RTT_JITTER" -v a="$RTT_ms" 'BEGIN { exit (j/a > 0.2) ? 0 : 1 }'; then
            MAX_BYTES=$(awk -v m="$MAX_BYTES" 'BEGIN{ printf "%.0f", m*1.2 }')
            note "High jitter detected (${RTT_JITTER}ms), buffer increased by 20%"
        fi
    fi

    # Dynamic tcp_max_tw_buckets
    MAX_TW_BUCKETS=$(get_max_tw_buckets)

    # Dynamic tcp_retries2 based on packet loss
    TCP_RETRIES2=8
    if [ -n "$RTT_LOSS" ]; then
        if [ "$RTT_LOSS" -gt 5 ]; then
            TCP_RETRIES2=12
            note "High packet loss (${RTT_LOSS}%), increasing tcp_retries2 to 12"
        elif [ "$RTT_LOSS" -gt 1 ]; then
            TCP_RETRIES2=10
            note "Moderate packet loss (${RTT_LOSS}%), increasing tcp_retries2 to 10"
        fi
    fi
    
    debug "BDP: $BDP_BYTES bytes, Max buffer: $MAX_BYTES bytes"
    
    # Dynamic default buffer sizes based on BDP bucket
    if [ "$MAX_MB" -ge 8 ]; then
        DEF_R=262144; DEF_W=262144
    else
        DEF_R=131072; DEF_W=131072
    fi
    
    # TCP buffer min/default/max (ESnet: tcp_wmem default=65536)
    TCP_RMEM_MIN=4096; TCP_RMEM_DEF=131072; TCP_RMEM_MAX=$MAX_BYTES
    TCP_WMEM_MIN=4096; TCP_WMEM_DEF=65536; TCP_WMEM_MAX=$MAX_BYTES
    
    # UDP memory limits
    UDP_MEM=$(get_udp_mem "$MEM_BYTES")
    
    # Dynamic queue sizes
    SOMAXCONN=$(get_somaxconn)
    NETDEV_BACKLOG=$(get_netdev_backlog)
    
    debug "Dynamic params: somaxconn=$SOMAXCONN, backlog=$NETDEV_BACKLOG, udp_mem=$UDP_MEM"
    
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
        if [ "$HAS_BBR2" = "1" ]; then
            modprobe tcp_bbr2 2>/dev/null || true
        else
            modprobe tcp_bbr 2>/dev/null || true
        fi
    fi
    
    # ---- Write and apply ----
    tmpf=$(mktemp) || bad "Failed to create temp file"
    trap 'rm -f "$tmpf"' EXIT INT TERM
    
    BDP_MB_display=$(awk -v b="$BDP_BYTES" 'BEGIN{ printf "%.2f", b/1024/1024 }')
    
    cat > "$tmpf" << SYSCTL_EOF
# =============================================================================
# Auto-generated by TuneTCP v${VERSION} (https://github.com/Michaol/tunetcp)
# Optimized for: IPv4 + IPv6, TCP + UDP (dual-stack compatible)
# =============================================================================
# Inputs: MEM_G=${MEM_G}GiB, BW=${BW_Mbps}Mbps, RTT=${RTT_ms}ms
# BDP: ${BDP_BYTES} bytes (~${BDP_MB_display} MB)
# Memory Tier: ${MEM_TIER}
# Caps: min(2*BDP, ${ram_pct}*RAM, ${cap_mb}MB) -> Bucket ${MAX_MB} MB

# -----------------------------------------------------------------------------
# Congestion Control & Queue Discipline
# -----------------------------------------------------------------------------
$(if [ "$HAS_BBR2" = "1" ]; then
    echo "net.core.default_qdisc = fq"
    echo "net.ipv4.tcp_congestion_control = bbr2"
elif [ "$HAS_BBR" = "1" ]; then
    echo "net.core.default_qdisc = fq"
    echo "net.ipv4.tcp_congestion_control = bbr"
else
    echo "# BBR not supported on this kernel, skipping CCA settings"
fi)

# -----------------------------------------------------------------------------
# Core Buffer Sizes (applies to both IPv4 and IPv6, TCP and UDP)
# -----------------------------------------------------------------------------
net.core.rmem_default = ${DEF_R}
net.core.wmem_default = ${DEF_W}
net.core.rmem_max = ${MAX_BYTES}
net.core.wmem_max = ${MAX_BYTES}
net.core.optmem_max = 524288

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
net.ipv4.tcp_notsent_lowat = 131072
net.ipv4.tcp_fastopen = 7
net.ipv4.tcp_fastopen_connect = 1
net.ipv4.tcp_moderate_rcvbuf = 1
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_sack = 1

# -----------------------------------------------------------------------------
# TCP Retransmission & Connection Management (Proxy/VPN optimized)
# -----------------------------------------------------------------------------
net.ipv4.tcp_retries1 = 3
net.ipv4.tcp_retries2 = ${TCP_RETRIES2}
net.ipv4.tcp_syn_retries = 2
net.ipv4.tcp_synack_retries = 2
net.ipv4.tcp_abort_on_overflow = 1
net.ipv4.tcp_max_tw_buckets = ${MAX_TW_BUCKETS}

# -----------------------------------------------------------------------------
# ECN & Thin Stream Optimization
# -----------------------------------------------------------------------------
net.ipv4.tcp_ecn = 1
net.ipv4.tcp_ecn_fallback = 1
net.ipv4.tcp_thin_linear_timeouts = 1
net.ipv4.tcp_thin_dupack = 1

# -----------------------------------------------------------------------------
# Connection Queue & Softirq Budget
# -----------------------------------------------------------------------------
net.core.somaxconn = ${SOMAXCONN}
net.ipv4.tcp_max_syn_backlog = ${SOMAXCONN}
net.core.netdev_max_backlog = ${NETDEV_BACKLOG}
net.core.netdev_budget = 600
net.core.netdev_budget_usecs = 8000

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
net.ipv4.tcp_syncookies = 1

# -----------------------------------------------------------------------------
# Port Range & UDP Settings (QUIC/WireGuard optimized)
# -----------------------------------------------------------------------------
net.ipv4.ip_local_port_range = 1024 65535
net.ipv4.udp_rmem_min = 16384
net.ipv4.udp_wmem_min = 16384
net.ipv4.udp_mem = ${UDP_MEM}

# -----------------------------------------------------------------------------
# File Descriptor & VM Tuning
# -----------------------------------------------------------------------------
fs.file-max = $([ "$MEM_TIER" = "low" ] && echo "262144" || echo "2097152")
vm.swappiness = $([ "$MEM_TIER" = "low" ] && echo "30" || echo "10")
vm.dirty_ratio = 15
vm.dirty_background_ratio = 5
SYSCTL_EOF

    # Validate config file
    if ! grep -E '^[a-zA-Z0-9_.-]+\s*=\s*.*$' "$tmpf" >/dev/null; then
        bad "Generated config file has invalid format"
    fi
    
    # Install config file
    if [ "$DRY_RUN" = "1" ]; then
        note "Dry-run mode: The following config would be written to $SYSCTL_TARGET:"
        printf %s\\n "--------------------------------------------------"
        cat "$tmpf"
        printf %s\\n "--------------------------------------------------"
    elif install -m 0644 "$tmpf" "$SYSCTL_TARGET"; then
        ok "Config file written: $SYSCTL_TARGET"
    else
        bad "Failed to write config file"
    fi
    
    # Apply configuration
    apply_sysctl_settings

    # Configure RPS/XPS and conntrack
    IFACE="$(default_iface)"
    configure_rps_xps "$IFACE"
    configure_conntrack
    
    # Apply tc qdisc
    IFACE="$(default_iface)"
    if command -v tc >/dev/null 2>&1 && [ -n "${IFACE-}" ]; then
        note "Setting fq qdisc for interface ${IFACE}..."
        if tc qdisc replace dev "$IFACE" root fq 2>/dev/null; then
            ok "TC qdisc applied successfully"
        else
            warn "Failed to apply TC qdisc"
        fi
    fi
    
    # ---- Verify critical params ----
    local expected_cc="bbr"
    if [ "$HAS_BBR2" = "1" ]; then
        expected_cc="bbr2"
    fi
    current_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "unknown")
    if [ "$current_cc" != "$expected_cc" ]; then
        warn "Expected $expected_cc but got $current_cc, please check kernel support"
    fi
    
    # ---- Output results ----
    ok "TCP/UDP optimization applied successfully!"
    echo
    echo "==== [ TuneTCP v${VERSION} Results ] ===="
    echo
    
    BDP_MB=$(awk -v b="$BDP_BYTES" 'BEGIN{ printf "%.2f", b/1024/1024 }')
    
    printf '%b[+] I. Input Parameters%b\n' "$GREEN" "$RESET"
    printf "    - %-12s : %s\n" "Memory" "${MEM_G} GiB (${MEM_TIER})"
    printf "    - %-12s : %s\n" "Bandwidth" "${BW_Mbps} Mbps"
    printf "    - %-12s : %s\n" "RTT" "${RTT_ms} ms"
    if [ -n "$RTT_JITTER" ]; then
        printf "    - %-12s : %s ms\n" "Jitter" "${RTT_JITTER}"
    fi
    if [ -n "$RTT_LOSS" ]; then
        printf "    - %-12s : %s%%\n" "Packet Loss" "${RTT_LOSS}"
    fi
    if [ -n "$RTT_TARGET" ]; then
        printf "    - %-12s : %s\n" "Ping Target" "${RTT_TARGET}"
    fi
    printf "    - %-12s : %s\n" "BDP" "${BDP_MB} MB"
    printf "    - %-12s : %s\n" "Buffer Max" "${MAX_MB} MB"
    echo
    
    printf '%b[+] II. Dynamic Parameters%b\n' "$GREEN" "$RESET"
    printf "    - %-25s : %s\n" "somaxconn" "${SOMAXCONN}"
    printf "    - %-25s : %s\n" "tcp_max_syn_backlog" "${SOMAXCONN}"
    printf "    - %-25s : %s\n" "netdev_max_backlog" "${NETDEV_BACKLOG}"
    printf "    - %-25s : %s\n" "udp_mem (low/pres/max)" "${UDP_MEM}"
    echo
    
    printf '%b[+] III. Kernel Verification%b\n' "$GREEN" "$RESET"
    printf "    - %-25s : %s\n" "TCP Congestion Control" "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "unknown")"
    printf "    - %-25s : %s\n" "Default Qdisc" "$(sysctl -n net.core.default_qdisc 2>/dev/null || echo "unknown")"
    printf "    - %-25s : %s (%s MB)\n" "Max Recv Buffer" "$(sysctl -n net.core.rmem_max 2>/dev/null || echo "unknown")" "$MAX_MB"
    printf "    - %-25s : %s (%s MB)\n" "Max Send Buffer" "$(sysctl -n net.core.wmem_max 2>/dev/null || echo "unknown")" "$MAX_MB"
    printf "    - %-25s : %s\n" "TCP rmem (min/def/max)" "$(sysctl -n net.ipv4.tcp_rmem 2>/dev/null || echo "unknown")"
    printf "    - %-25s : %s\n" "TCP wmem (min/def/max)" "$(sysctl -n net.ipv4.tcp_wmem 2>/dev/null || echo "unknown")"
    printf "    - %-25s : %s\n" "TCP Window Scaling" "$(sysctl -n net.ipv4.tcp_window_scaling 2>/dev/null || echo "unknown")"
    printf "    - %-25s : %s\n" "TCP Timestamps" "$(sysctl -n net.ipv4.tcp_timestamps 2>/dev/null || echo "unknown")"
    printf "    - %-25s : %s\n" "TCP SACK" "$(sysctl -n net.ipv4.tcp_sack 2>/dev/null || echo "unknown")"
    printf "    - %-25s : %s\n" "TCP SYN Cookies" "$(sysctl -n net.ipv4.tcp_syncookies 2>/dev/null || echo "unknown")"
    printf "    - %-25s : %s\n" "TCP Fast Open" "$(sysctl -n net.ipv4.tcp_fastopen 2>/dev/null || echo "unknown")"
    printf "    - %-25s : %s\n" "TCP notsent_lowat" "$(sysctl -n net.ipv4.tcp_notsent_lowat 2>/dev/null || echo "unknown")"
    printf "    - %-25s : %s\n" "UDP rmem_min" "$(sysctl -n net.ipv4.udp_rmem_min 2>/dev/null || echo "unknown")"
    printf "    - %-25s : %s\n" "UDP wmem_min" "$(sysctl -n net.ipv4.udp_wmem_min 2>/dev/null || echo "unknown")"
    printf "    - %-25s : %s\n" "UDP mem" "$(sysctl -n net.ipv4.udp_mem 2>/dev/null || echo "unknown")"
    echo
    
    if command -v tc >/dev/null 2>&1 && [ -n "${IFACE-}" ]; then
        printf '%b[+] IV. Network Interface%b\n' "$GREEN" "$RESET"
        printf "    - Interface %-10s : %s\n" "${IFACE}" "$(tc qdisc show dev "$IFACE" 2>/dev/null | head -1 || echo "unknown")"
    fi

    printf '%b[+] V. Proxy/VPN Optimizations%b\n' "$GREEN" "$RESET"
    printf "    - %-25s : %s\n" "BBR Version" "$([ "$HAS_BBR2" = "1" ] && echo "BBRv2" || echo "BBRv1")"
    printf "    - %-25s : %s\n" "Memory Profile" "$MEM_TIER"
    printf "    - %-25s : %s\n" "RPS/XPS" "$([ "$RPS_CONFIGURED" = "1" ] && echo "Enabled" || echo "N/A")"
    printf "    - %-25s : %s\n" "Conntrack" "$([ "$CONNTRACK_AVAILABLE" = "1" ] && echo "Enabled" || echo "N/A")"
    printf "    - %-25s : %s\n" "tcp_retries2" "${TCP_RETRIES2}"
    printf "    - %-25s : %s\n" "tcp_max_tw_buckets" "${MAX_TW_BUCKETS}"
    printf "    - %-25s : %s\n" "fs.file-max" "$(sysctl -n fs.file-max 2>/dev/null || echo "unknown")"
    
    echo "=========================================="
    echo
    note "Config file: $SYSCTL_TARGET"
    note "Uninstall: $0 --uninstall"
    
    debug "TuneTCP execution completed successfully"
}

# Execute main function
main "$@"
