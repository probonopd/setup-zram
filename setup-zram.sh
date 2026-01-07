#!/bin/sh
#
# zram Setup Script - Portable across distributions and init systems
# Supports: systemd, OpenRC, SysVinit
# Requires: POSIX sh, standard Unix utilities
# https://github.com/probonopd/setup-zram/
#

set -e

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'  # No Color

# Log functions
log_info() {
    printf "%b[INFO]%b %s\n" "$GREEN" "$NC" "$1" >&2
}

log_warn() {
    printf "%b[WARN]%b %s\n" "$YELLOW" "$NC" "$1" >&2
}

log_error() {
    printf "%b[ERROR]%b %s\n" "$RED" "$NC" "$1" >&2
}

# Check if running as root
check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        log_error "This script must be run as root"
        exit 1
    fi
}

# Detect init system
detect_init_system() {
    if [ -d /run/systemd/system ]; then
        echo "systemd"
    elif command -v rc-update >/dev/null 2>&1; then
        echo "openrc"
    elif [ -d /etc/init.d ]; then
        echo "sysvinit"
    else
        log_error "Unable to detect init system"
        exit 1
    fi
}

# Detect OS/Distribution
detect_distro() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        echo "$ID"
    elif [ -f /etc/lsb-release ]; then
        . /etc/lsb-release
        echo "$DISTRIB_ID" | tr '[:upper:]' '[:lower:]'
    else
        uname -s
    fi
}

# Get total RAM in MB
get_total_ram_mb() {
    grep MemTotal /proc/meminfo | awk '{print int($2/1024)}'
}

# Calculate appropriate zram size based on RAM
calculate_zram_size() {
    local total_ram=$1
    local zram_size
    
    # Smart heuristic based on system size:
    # - Small systems (<2GB): 25% to preserve responsiveness
    # - Medium systems (2-8GB): 50% for good swap coverage
    # - Large systems (>8GB): 4-6GB capped (compression ratio 2:1-3:1 = 8-18GB virtual)
    
    if [ "$total_ram" -lt 2048 ]; then
        # Small systems: 25% of RAM
        zram_size=$((total_ram / 4))
    elif [ "$total_ram" -lt 8192 ]; then
        # Medium systems: 50% of RAM
        zram_size=$((total_ram / 2))
    else
        # Large systems: min(50% of RAM, 6GB)
        zram_size=$((total_ram / 2))
        if [ "$zram_size" -gt 6144 ]; then
            zram_size=6144
        fi
    fi
    
    # Minimum 256MB required
    if [ "$zram_size" -lt 256 ]; then
        log_error "System RAM too low (${total_ram}MB). Not creating zram."
        exit 1
    fi
    
    echo "$zram_size"
}

# Check if zram module is available
check_zram_module() {
    if ! modinfo zram >/dev/null 2>&1; then
        log_error "zram module not available on this system"
        exit 1
    fi
}

# Load zram module
load_zram_module() {
    log_info "Loading zram module..."
    modprobe zram num_devices=1 || {
        log_error "Failed to load zram module"
        exit 1
    }
    sleep 1
}

# Initialize zram device
init_zram_device() {
    local zram_size_mb=$1
    
    log_info "Initializing /dev/zram0 with ${zram_size_mb}MB..."
    
    # Convert to suitable format
    if [ "$zram_size_mb" -ge 1024 ]; then
        local size_gb=$((zram_size_mb / 1024))
        echo "${size_gb}G" > /sys/block/zram0/disksize
    else
        echo "${zram_size_mb}M" > /sys/block/zram0/disksize
    fi
    
    # Create swap
    log_info "Setting up swap..."
    mkswap /dev/zram0 >/dev/null 2>&1 || {
        log_error "Failed to create swap on /dev/zram0"
        exit 1
    }
    
    swapon /dev/zram0 || {
        log_error "Failed to activate swap"
        exit 1
    }
}

# Create systemd service
create_systemd_service() {
    local service_file="/etc/systemd/system/zram.service"
    local zram_script="/usr/local/bin/zram-init.sh"
    
    log_info "Creating systemd service..."
    
    # Create init script
    cat > "$zram_script" << 'INITEOF'
#!/bin/sh
modprobe zram num_devices=1 2>/dev/null
sleep 1
echo 2G > /sys/block/zram0/disksize 2>/dev/null || echo 1G > /sys/block/zram0/disksize 2>/dev/null
mkswap /dev/zram0 2>/dev/null
swapon /dev/zram0 2>/dev/null
INITEOF
    chmod +x "$zram_script"
    
    # Create service file
    cat > "$service_file" << 'SVCEOF'
[Unit]
Description=Initialize ZRAM compressed swap device
After=systemd-modules-load.service
Before=swap.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/zram-init.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
SVCEOF
    
    systemctl daemon-reload
    systemctl enable zram.service
    log_info "systemd service created and enabled"
}

# Create OpenRC service
create_openrc_service() {
    local init_file="/etc/init.d/zram"
    
    log_info "Creating OpenRC service..."
    
    cat > "$init_file" << 'OPENRCEOF'
#!/bin/sh

### BEGIN INIT INFO
# Provides:          zram
# Required-Start:    $local_fs
# Required-Stop:     $local_fs
# Default-Start:     2 3 4 5
# Default-Stop:      0 1 6
# Short-Description: Initialize ZRAM swap device
# Description:       Initialize ZRAM compressed RAM-based swap device
### END INIT INFO

depend() {
    need localmount
    before swap
}

start() {
    ebegin "Starting ZRAM swap device"
    
    modprobe zram num_devices=1 2>/dev/null
    sleep 1
    
    echo 2G > /sys/block/zram0/disksize 2>/dev/null || echo 1G > /sys/block/zram0/disksize 2>/dev/null
    mkswap /dev/zram0 2>/dev/null
    swapon /dev/zram0 2>/dev/null
    
    eend $?
}

stop() {
    ebegin "Stopping ZRAM swap device"
    
    swapoff /dev/zram0 2>/dev/null
    echo 1 > /sys/block/zram0/reset 2>/dev/null
    modprobe -r zram 2>/dev/null
    
    eend $?
}

status() {
    if [ -e /dev/zram0 ]; then
        einfo "ZRAM device is active"
        swapon -s 2>/dev/null | grep zram
    else
        einfo "ZRAM device not found"
    fi
}
OPENRCEOF
    
    chmod +x "$init_file"
    
    if command -v rc-update >/dev/null 2>&1; then
        rc-update add zram default 2>/dev/null || true
        log_info "OpenRC service created and registered"
    else
        log_warn "rc-update not found, service created but not auto-registered"
    fi
}

# Create SysVinit service
create_sysvinit_service() {
    local init_file="/etc/init.d/zram"
    
    log_info "Creating SysVinit service..."
    
    cat > "$init_file" << 'SYSVINITEOF'
#!/bin/sh

### BEGIN INIT INFO
# Provides:          zram
# Required-Start:    $local_fs
# Required-Stop:     $local_fs
# Default-Start:     2 3 4 5
# Default-Stop:      0 1 6
# Short-Description: Initialize ZRAM swap device
# Description:       Initialize ZRAM compressed RAM-based swap device
### END INIT INFO

case "$1" in
    start)
        echo "Starting ZRAM swap device..."
        
        modprobe zram num_devices=1 2>/dev/null
        sleep 1
        
        echo 2G > /sys/block/zram0/disksize 2>/dev/null || echo 1G > /sys/block/zram0/disksize 2>/dev/null
        mkswap /dev/zram0 2>/dev/null
        swapon /dev/zram0 2>/dev/null
        
        echo "ZRAM swap device initialized"
        ;;
        
    stop)
        echo "Stopping ZRAM swap device..."
        
        swapoff /dev/zram0 2>/dev/null
        echo 1 > /sys/block/zram0/reset 2>/dev/null
        modprobe -r zram 2>/dev/null
        
        echo "ZRAM swap device stopped"
        ;;
        
    restart)
        $0 stop
        sleep 1
        $0 start
        ;;
        
    status)
        if [ -e /dev/zram0 ]; then
            echo "ZRAM device is active"
            swapon -s 2>/dev/null | grep zram || echo "No swap on /dev/zram0"
        else
            echo "ZRAM device not found"
        fi
        ;;
        
    *)
        echo "Usage: $0 {start|stop|restart|status}"
        exit 1
        ;;
esac

exit 0
SYSVINITEOF
    
    chmod +x "$init_file"
    
    if command -v update-rc.d >/dev/null 2>&1; then
        update-rc.d zram defaults >/dev/null 2>&1 || true
        log_info "SysVinit service created and registered"
    elif command -v chkconfig >/dev/null 2>&1; then
        chkconfig --add zram >/dev/null 2>&1 || true
        log_info "SysVinit service created and registered with chkconfig"
    else
        log_warn "Unable to register service with init system tools"
    fi
}

# Setup persistence based on init system
setup_persistence() {
    local init_system=$1
    
    case "$init_system" in
        systemd)
            create_systemd_service
            ;;
        openrc)
            create_openrc_service
            ;;
        sysvinit)
            create_sysvinit_service
            ;;
        *)
            log_error "Unknown init system: $init_system"
            exit 1
            ;;
    esac
}

# Display current status
show_status() {
    log_info "Current status:"
    echo ""
    
    printf "%-20s: %s\n" "Init System" "$(detect_init_system)"
    printf "%-20s: %s\n" "Distribution" "$(detect_distro)"
    printf "%-20s: %s MB\n" "Total RAM" "$(get_total_ram_mb)"
    echo ""
    
    echo "Memory Info:"
    free -h
    echo ""
    
    if swapon -s 2>/dev/null | grep -q zram; then
        echo "ZRAM Swap Info:"
        swapon -s | grep zram
        echo ""
        
        if [ -f /sys/block/zram0/mm_stat ]; then
            echo "Compression Statistics:"
            read -r orig compr total _ mem_max _ _ _ _ < /sys/block/zram0/mm_stat
            if [ "$compr" -gt 0 ]; then
                orig_mb=$((orig / 1024))
                compr_mb=$((compr / 1024))
                # Use awk for ratio calculation to avoid integer overflow
                ratio=$(awk "BEGIN {printf \"%.2f\", $orig / $compr}")
                printf "  Original Size: %d MB\n" "$orig_mb"
                printf "  Compressed Size: %d MB\n" "$compr_mb"
                printf "  Compression Ratio: %s:1\n" "$ratio"
            fi
        fi
    else
        log_warn "ZRAM swap not currently active"
    fi
}

# Main installation flow
install_zram() {
    check_root
    
    log_info "Starting zram setup..."
    echo ""
    
    # Detect system configuration
    local init_system=$(detect_init_system)
    local distro=$(detect_distro)
    local total_ram=$(get_total_ram_mb)
    local zram_size=$(calculate_zram_size "$total_ram")
    
    log_info "Detected: $distro | Init: $init_system | RAM: ${total_ram}MB"
    log_info "Will create ${zram_size}MB zram swap"
    echo ""
    
    # Pre-flight checks
    check_zram_module
    
    # Check if zram is already active
    if [ -e /dev/zram0 ]; then
        log_warn "zram device already exists, resetting..."
        swapoff /dev/zram0 2>/dev/null || true
        modprobe -r zram 2>/dev/null || true
        sleep 1
    fi
    
    # Setup zram
    load_zram_module
    init_zram_device "$zram_size"
    
    log_info "zram initialized successfully"
    echo ""
    
    # Setup persistence
    setup_persistence "$init_system"
    
    echo ""
    log_info "Setup complete! zram will auto-initialize on boot"
    echo ""
    
    # Show status
    show_status
}

# Usage information
usage() {
    cat << EOF
Usage: $0 [COMMAND]

Commands:
    install     Install and configure zram (default)
    remove      Remove zram swap and service
    status      Show current zram status
    help        Show this help message

Environment Variables:
    ZRAM_SIZE_MB    Override calculated zram size (in MB)

Example:
    $0 install
    ZRAM_SIZE_MB=1024 $0 install
    $0 status
    $0 remove

EOF
}

# Remove zram
remove_zram() {
    check_root
    
    log_info "Removing zram setup..."
    
    # Deactivate swap
    swapoff /dev/zram0 2>/dev/null || true
    
    # Reset device
    echo 1 > /sys/block/zram0/reset 2>/dev/null || true
    
    # Unload module
    modprobe -r zram 2>/dev/null || true
    
    # Remove init scripts
    local init_system=$(detect_init_system)
    
    case "$init_system" in
        systemd)
            systemctl disable zram.service 2>/dev/null || true
            rm -f /etc/systemd/system/zram.service
            rm -f /usr/local/bin/zram-init.sh
            systemctl daemon-reload 2>/dev/null || true
            ;;
        openrc)
            rc-update del zram default 2>/dev/null || true
            rm -f /etc/init.d/zram
            ;;
        sysvinit)
            if command -v update-rc.d >/dev/null 2>&1; then
                update-rc.d zram remove 2>/dev/null || true
            elif command -v chkconfig >/dev/null 2>&1; then
                chkconfig --del zram 2>/dev/null || true
            fi
            rm -f /etc/init.d/zram
            ;;
    esac
    
    log_info "zram removed successfully"
}

# Main dispatcher
main() {
    case "${1:-install}" in
        install)
            install_zram
            ;;
        remove)
            remove_zram
            ;;
        status)
            show_status
            ;;
        help)
            usage
            ;;
        *)
            log_error "Unknown command: $1"
            usage
            exit 1
            ;;
    esac
}

main "$@"
