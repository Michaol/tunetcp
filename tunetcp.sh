#!/usr/bin/env bash
set -eu
set -o pipefail 2>/dev/null || true

# =========================================================
# TuneTCP v3.0 - 最激进TCP/UDP网络优化工具
# - 性能优先策略，最大化网络吞吐量
# - 支持BBR自动检测，分级内存优化
# - 双栈支持IPv4+IPv6，兼容所有Linux发行版
# https://github.com/Michaol/tunetcp
# =========================================================

VERSION="3.0.0"
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
    ping_target=""
    ping_desc=""

    if [ -n "${SSH_CONNECTION-}" ]; then
        ping_target=$(echo "$SSH_CONNECTION" | awk '{print $1}')
        ping_desc="SSH client ${ping_target}"
        note "Auto-detected SSH client IP: ${ping_target}"
    elif [ "$SKIP_CONFIRM" != "1" ]; then
        note "No SSH connection detected, please provide a client IP."
        printf "Enter client IP for ping test (press Enter for 1.1.1.1): " </dev/tty
        read -r client_ip 2>/dev/null || client_ip=""
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
    
    # Check if ping is available and works
    if ! command -v ping >/dev/null 2>&1; then
        warn "ping command not available, using default 150 ms"
        echo "150"
        return
    fi
    
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
net.ipv4.tcp_rmem \
net.ipv4.tcp_wmem \
net.ipv4.tcp_congestion_control \
net.ipv4.tcp_slow_start_after_idle \
net.ipv4.tcp_notsent_lowat \
net.core.somaxconn \
net.ipv4.tcp_max_syn_backlog \
net.core.netdev_max_backlog \
net.ipv4.ip_local_port_range \
net.ipv4.udp_rmem_min \
net.ipv4.udp_wmem_min \
net.core.optmem_max \
net.ipv4.tcp_fastopen \
net.ipv4.tcp_fin_timeout \
net.ipv4.tcp_tw_reuse \
net.ipv4.tcp_keepalive \
net.ipv4.tcp_syncookies \
net.ipv4.tcp_max_tw_buckets \
net.ipv4.tcp_window_scaling \
net.ipv4.tcp_timestamps \
net.ipv4.tcp_sack \
net.ipv4.tcp_mtu_probing"

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

# --- Dynamic bucket functions ---
bucket_le_mb() {
    local mb="${1:-0}"
    case $mb in
        [6-9][0-9]*) echo 64 ;;
        3[2-9]*) echo 32 ;;
        1[6-9]*) echo 16 ;;
        8*) echo 8 ;;
        4*) echo 4 ;;
        *) echo 4 ;;
    esac
}

# Dynamic somaxconn based on memory
get_somaxconn() {
    local mem_int=$(printf "%.0f" "$MEM_G")
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
    
    # Calculate parameters - AGGRESSIVE STRATEGY for v3.0
    show_progress 5 5 "Calculating optimization parameters (AGGRESSIVE)..."
    note "Calculating BDP and buffer sizes with aggressive strategy..."
    
    BDP_BYTES=$(awk -v bw="$BW_Mbps" -v rtt="$RTT_ms" 'BEGIN{ printf "%.0f", bw*125*rtt }')
    MEM_BYTES=$(get_mem_bytes "$MEM_G")
    FOUR_BDP=$(( BDP_BYTES*4 ))
    
    # Tiered aggressive strategy based on memory size
    mem_g_int=$(printf "%.0f" "$MEM_G")
    if [ "$mem_g_int" -ge 2 ]; then
        # 2GB+: Fully aggressive
        MIN_BUF=$(( 256*1024*1024 ))  # 256MB minimum
        CAP_BUF=$(( 512*1024*1024 ))  # 512MB cap
        RAM_PCT=0.10
        TCP_RMEM_MIN=16384; TCP_RMEM_DEF=524288    # 16KB, 512KB
        TCP_WMEM_MIN=16384; TCP_WMEM_DEF=524288
        UDP_RMEM_MIN=65536; UDP_WMEM_MIN=65536     # 64KB
        DEF_R=262144; DEF_W=524288                 # 256KB, 512KB
    elif [ "$mem_g_int" -ge 1 ]; then
        # 1-2GB: Standard aggressive
        MIN_BUF=$(( 128*1024*1024 ))  # 128MB minimum
        CAP_BUF=$(( 256*1024*1024 ))  # 256MB cap
        RAM_PCT=0.10
        TCP_RMEM_MIN=8192; TCP_RMEM_DEF=262144     # 8KB, 256KB
        TCP_WMEM_MIN=8192; TCP_WMEM_DEF=262144
        UDP_RMEM_MIN=32768; UDP_WMEM_MIN=32768     # 32KB
        DEF_R=131072; DEF_W=262144                 # 128KB, 256KB
    else
        # 512MB-1GB: Conservative aggressive
        MIN_BUF=$(( 64*1024*1024 ))   # 64MB minimum
        CAP_BUF=$(( 128*1024*1024 ))  # 128MB cap
        RAM_PCT=0.08
        TCP_RMEM_MIN=8192; TCP_RMEM_DEF=131072     # 8KB, 128KB
        TCP_WMEM_MIN=8192; TCP_WMEM_DEF=131072
        UDP_RMEM_MIN=16384; UDP_WMEM_MIN=16384     # 16KB
        DEF_R=131072; DEF_W=131072                 # 128KB, 128KB
    fi
    
    RAM_PCT_BYTES=$(awk -v m="$MEM_BYTES" -v pct="$RAM_PCT" 'BEGIN{ printf "%.0f", m*pct }')
    
    # Take max of 4*BDP and RAM%, but not less than MIN_BUF, not more than CAP_BUF
    MAX_BYTES=$(awk -v bdp="$FOUR_BDP" -v ram="$RAM_PCT_BYTES" -v min="$MIN_BUF" -v cap="$CAP_BUF" \
        'BEGIN{ m=bdp; if(ram>m)m=ram; if(m<min)m=min; if(m>cap)m=cap; printf "%.0f", m }')
    MAX_MB=$(( MAX_BYTES/1024/1024 ))
    
    debug "BDP: $BDP_BYTES bytes, 4*BDP: $FOUR_BDP, Max buffer: $MAX_BYTES bytes ($MAX_MB MB)"
    
    # TCP buffer max values
    TCP_RMEM_MAX=$MAX_BYTES
    TCP_WMEM_MAX=$MAX_BYTES
    
    # Fixed queue sizes at maximum (aggressive)
    SOMAXCONN=65535
    NETDEV_BACKLOG=65535
    
    debug "Aggressive params: somaxconn=$SOMAXCONN, backlog=$NETDEV_BACKLOG"
    
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
    tmpf=$(mktemp) || bad "Failed to create temp file"
    trap 'rm -f "$tmpf"' EXIT INT TERM
    
    BDP_MB_display=$(awk -v b="$BDP_BYTES" 'BEGIN{ printf "%.2f", b/1024/1024 }')
    
    cat > "$tmpf" << SYSCTL_EOF
# =============================================================================
# Auto-generated by TuneTCP v${VERSION} - AGGRESSIVE MODE
# https://github.com/Michaol/tunetcp
# Optimized for: IPv4 + IPv6, TCP + UDP (dual-stack compatible)
# =============================================================================
# Inputs: MEM_G=${MEM_G}GiB, BW=${BW_Mbps}Mbps, RTT=${RTT_ms}ms
# BDP: ${BDP_BYTES} bytes (~${BDP_MB_display} MB), 4*BDP: ${FOUR_BDP}
# Strategy: max(4*BDP, ${RAM_PCT}*RAM, MIN_BUF) -> ${MAX_MB} MB

# -----------------------------------------------------------------------------
# Congestion Control & Queue Discipline
# -----------------------------------------------------------------------------
$(if [ "$HAS_BBR" = "1" ]; then
    echo "net.core.default_qdisc = fq"
    echo "net.ipv4.tcp_congestion_control = bbr"
else
    echo "# BBR not supported on this kernel, skipping CCA settings"
fi)

# -----------------------------------------------------------------------------
# Core Buffer Sizes (AGGRESSIVE - applies to both IPv4 and IPv6)
# -----------------------------------------------------------------------------
net.core.rmem_default = ${DEF_R}
net.core.wmem_default = ${DEF_W}
net.core.rmem_max = ${MAX_BYTES}
net.core.wmem_max = ${MAX_BYTES}
net.core.optmem_max = 262144

# -----------------------------------------------------------------------------
# TCP Buffer Sizes (AGGRESSIVE - shared by IPv4 and IPv6 TCP stack)
# Format: min default max
# -----------------------------------------------------------------------------
net.ipv4.tcp_rmem = ${TCP_RMEM_MIN} ${TCP_RMEM_DEF} ${TCP_RMEM_MAX}
net.ipv4.tcp_wmem = ${TCP_WMEM_MIN} ${TCP_WMEM_DEF} ${TCP_WMEM_MAX}

# Note: tcp_mem removed to let kernel auto-manage memory pressure

# -----------------------------------------------------------------------------
# TCP Performance Tuning (AGGRESSIVE)
# -----------------------------------------------------------------------------
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_notsent_lowat = 16384
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_sack = 1
net.ipv4.tcp_no_metrics_save = 1
net.ipv4.tcp_moderate_rcvbuf = 0

# Enable ECN (Explicit Congestion Notification)
net.ipv4.tcp_ecn = 1
net.ipv4.tcp_ecn_fallback = 1

# -----------------------------------------------------------------------------
# Connection Queue Sizes (FIXED AT MAXIMUM - AGGRESSIVE)
# -----------------------------------------------------------------------------
net.core.somaxconn = ${SOMAXCONN}
net.ipv4.tcp_max_syn_backlog = ${SOMAXCONN}
net.core.netdev_max_backlog = ${NETDEV_BACKLOG}

# Network device buffer (AGGRESSIVE)
net.core.netdev_budget = 50000
net.core.netdev_budget_usecs = 5000

# -----------------------------------------------------------------------------
# TCP Keepalive & Timeout Settings (AGGRESSIVE - minimize latency)
# -----------------------------------------------------------------------------
net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_keepalive_intvl = 15
net.ipv4.tcp_keepalive_probes = 5
net.ipv4.tcp_fin_timeout = 10

# -----------------------------------------------------------------------------
# TCP Connection Reuse & Limits
# -----------------------------------------------------------------------------
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_max_tw_buckets = 65535
net.ipv4.tcp_max_orphans = 32768
net.ipv4.tcp_syncookies = 1

# -----------------------------------------------------------------------------
# Port Range & UDP Settings (AGGRESSIVE)
# -----------------------------------------------------------------------------
net.ipv4.ip_local_port_range = 1024 65535
net.ipv4.udp_rmem_min = ${UDP_RMEM_MIN}
net.ipv4.udp_wmem_min = ${UDP_WMEM_MIN}

# -----------------------------------------------------------------------------
# IPv6 Optimization (ensure enabled)
# -----------------------------------------------------------------------------
net.ipv6.conf.all.disable_ipv6 = 0
net.ipv6.conf.default.disable_ipv6 = 0
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
    
    # Apply tc qdisc with aggressive FQ parameters
    IFACE="$(default_iface)"
    if command -v tc >/dev/null 2>&1 && [ -n "${IFACE-}" ]; then
        note "Setting aggressive fq qdisc for interface ${IFACE}..."
        if tc qdisc replace dev "$IFACE" root fq \
            limit 100000 \
            flow_limit 1000 \
            quantum 3028 \
            initial_quantum 15140 \
            maxrate 0 \
            buckets 1024 \
            orphan_mask 1023 \
            pacing \
            ce_threshold 0 2>/dev/null; then
            ok "TC qdisc applied successfully with aggressive parameters"
        else
            warn "Failed to apply aggressive TC qdisc, trying basic fq..."
            if tc qdisc replace dev "$IFACE" root fq 2>/dev/null; then
                ok "TC qdisc applied with basic fq"
            else
                warn "Failed to apply TC qdisc"
            fi
        fi
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
    printf "    - %-25s : %s\n" "UDP rmem_min" "$(sysctl -n net.ipv4.udp_rmem_min 2>/dev/null || echo "unknown")"
    printf "    - %-25s : %s\n" "UDP wmem_min" "$(sysctl -n net.ipv4.udp_wmem_min 2>/dev/null || echo "unknown")"
    echo
    
    if command -v tc >/dev/null 2>&1 && [ -n "${IFACE-}" ]; then
        printf '%b[+] IV. Network Interface%b\n' "$GREEN" "$RESET"
        printf "    - Interface %-10s : %s\n" "${IFACE}" "$(tc qdisc show dev "$IFACE" 2>/dev/null | head -1 || echo "unknown")"
    fi
    
    echo "=========================================="
    echo
    note "Config file: $SYSCTL_TARGET"
    note "Uninstall: $0 --uninstall"
    
    debug "TuneTCP execution completed successfully"
}

# Execute main function
main "$@"
