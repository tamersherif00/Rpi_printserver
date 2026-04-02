#!/bin/bash
# Print Server Installation Script
# Installs and configures all components for the Raspberry Pi print server

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Configuration
INSTALL_DIR="/opt/printserver"
CONFIG_DIR="/etc/printserver"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root (use sudo)"
        exit 1
    fi

    # Get the actual user who ran sudo (for later user configuration)
    ACTUAL_USER="${SUDO_USER:-$USER}"
}

check_raspberry_pi() {
    if [[ ! -f /proc/device-tree/model ]]; then
        log_warn "This does not appear to be a Raspberry Pi"
        read -p "Continue anyway? (y/n) " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            exit 1
        fi
    else
        MODEL=$(tr -d '\0' < /proc/device-tree/model)
        log_info "Detected: $MODEL"

        # Verify supported models (Pi 3, 4, 5, Zero 2 W)
        if echo "$MODEL" | grep -qiE "(Pi 3|Pi 4|Pi 5|Zero 2)"; then
            log_info "Supported Raspberry Pi model detected"
        elif echo "$MODEL" | grep -qiE "(Pi Zero W|Pi Zero$)"; then
            log_warn "Pi Zero (original) detected - may have limited performance"
            log_warn "Recommended: Raspberry Pi Zero 2 W or newer"
        else
            log_warn "Untested model - proceeding anyway"
        fi
    fi
}

install_system_packages() {
    log_info "Updating package lists..."
    apt-get update

    # â”€â”€ Mandatory packages â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
    # These are required for the print server to function; exit on failure.
    log_info "Installing required packages..."
    apt-get install -y \
        cups \
        cups-bsd \
        avahi-daemon \
        avahi-utils \
        python3 \
        python3-pip \
        python3-venv \
        python3-cups \
        samba \
        wireless-tools

    # â”€â”€ Optional system packages â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
    # Package names and availability vary across Debian/Raspbian releases
    # (e.g. cups-browsed was split from cups-filters in Debian Trixie+).
    # Install each individually so a missing package doesn't abort the script.
    # NOTE: cups-browsed is installed but DISABLED — it discovers remote printers
    # which conflicts with our local USB printer setup (creates duplicate queues,
    # stale dbus subscriptions that crash CUPS 2.4.x).
    for pkg in cups-filters cups-browsed libcups2-dev; do
        if apt-get install -y "$pkg" 2>/dev/null; then
            log_info "  installed: $pkg"
        else
            log_warn "$pkg not available in current repos â€” skipping (non-fatal)"
        fi
    done

    # â”€â”€ wsdd: Windows 10/11 auto-discovery via WS-Discovery â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
    # Strategy:
    #   1. Try apt  (available on Bullseye/Bookworm; removed from Trixie+).
    #   2. Download the standalone Python script from the upstream GitHub repo.
    #      wsdd is NOT published to PyPI â€” pip install wsdd will always fail.
    #   3. Warn and provide manual-add instructions if both methods fail.
    if apt-get install -y wsdd 2>/dev/null; then
        log_info "wsdd installed from apt"
        # The apt package ships its own service file (ExecStart without -w).
        # Add a drop-in that overrides ExecStart to include -w WORKGROUP so
        # Windows places the device in the right network group for discovery.
        local apt_svc=""
        for f in /lib/systemd/system/wsdd.service /usr/lib/systemd/system/wsdd.service; do
            [[ -f "$f" ]] && { apt_svc="$f"; break; }
        done
        if [[ -n "$apt_svc" ]]; then
            local wsdd_bin
            wsdd_bin=$(grep "^ExecStart=" "$apt_svc" | head -1 | sed 's/ExecStart=//' | awk '{print $1}')
            if [[ -n "$wsdd_bin" ]]; then
                mkdir -p /etc/systemd/system/wsdd.service.d
                printf '[Service]\nExecStart=\nExecStart=%s -w WORKGROUP\n' "$wsdd_bin" \
                    > /etc/systemd/system/wsdd.service.d/printserver.conf
                systemctl daemon-reload
                log_info "wsdd: applied -w WORKGROUP via systemd drop-in"
            fi
        fi
    else
        log_info "apt wsdd unavailable â€” downloading from GitHub (christgau/wsdd)..."
        WSDD_BIN="/usr/local/bin/wsdd"
        if wget -q -O "$WSDD_BIN" \
               "https://raw.githubusercontent.com/christgau/wsdd/master/src/wsdd.py" \
            && chmod +x "$WSDD_BIN"; then

            # Only write the unit file if apt didn't already install one.
            if [[ ! -f /lib/systemd/system/wsdd.service ]] && \
               [[ ! -f /usr/lib/systemd/system/wsdd.service ]]; then
                cat > /etc/systemd/system/wsdd.service << 'WSDD_EOF'
[Unit]
Description=Web Services Dynamic Discovery Daemon
Documentation=https://github.com/christgau/wsdd
After=network-online.target
Wants=network-online.target

[Service]
# -w WORKGROUP  must match the workgroup in smb.conf so Windows places
#               the device in the right network group for discovery.
ExecStart=/usr/local/bin/wsdd -w WORKGROUP
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
WSDD_EOF
                systemctl daemon-reload
            fi
            log_info "wsdd installed from GitHub, systemd unit created"
        else
            log_warn "wsdd could not be installed (apt unavailable, GitHub download failed)."
            log_warn "Windows auto-discovery via WSD will not work automatically."
            log_warn "Windows users can still add the printer manually:"
            log_warn "  SMB path: \\\\$(hostname)\\<PrinterName>"
            log_warn "  IPP URL:  http://$(hostname -I | awk '{print \$1}'):631/printers/<PrinterName>"
        fi
    fi

    # â”€â”€ Optional printer drivers â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
    log_info "Installing printer drivers (where available)..."
    for pkg in printer-driver-brlaser printer-driver-cups-pdf printer-driver-gutenprint; do
        if apt-cache show "$pkg" > /dev/null 2>&1; then
            apt-get install -y "$pkg" && log_info "  installed: $pkg"
        else
            log_warn "  $pkg not available in current repos â€” skipping"
        fi
    done

    # Add user to lpadmin group for CUPS administration
    if [[ -n "$ACTUAL_USER" ]] && [[ "$ACTUAL_USER" != "root" ]]; then
        log_info "Adding user '$ACTUAL_USER' to lpadmin group..."
        usermod -a -G lpadmin "$ACTUAL_USER"
    fi

    log_info "System packages installed successfully"
}

install_brother_driver() {
    # Check if Brother printer is connected but not working
    if lpinfo -v 2>/dev/null | grep -q "usb://Brother"; then
        BROTHER_MODEL=$(lpinfo -v 2>/dev/null | grep "usb://Brother" | head -1)
        log_info "Brother printer detected: $BROTHER_MODEL"

        # Check if driver is needed
        if ! lpstat -p 2>/dev/null | grep -q "Brother"; then
            log_info "Attempting to auto-configure Brother printer..."

            # Try driverless first (IPP Everywhere)
            log_info "Trying driverless setup..."

            # If that doesn't work, provide instructions for manual driver
            log_warn "If your Brother printer doesn't work, you may need to:"
            log_warn "1. Download driver from https://support.brother.com"
            log_warn "2. Select 'Linux' and 'Linux (deb)'"
            log_warn "3. Download and install the Driver Install Tool"
            log_warn "   wget https://download.brother.com/welcome/dlf006893/linux-brprinter-installer-*.gz"
            log_warn "   gunzip linux-brprinter-installer-*.gz"
            log_warn "   sudo bash linux-brprinter-installer-* [ModelName]"
        fi
    fi
}

create_directories() {
    log_info "Creating directories..."

    mkdir -p "$INSTALL_DIR"
    mkdir -p "$CONFIG_DIR"
    mkdir -p /var/log/printserver
    mkdir -p /var/lib/printserver   # WOL device store (wol_devices.json)

    chown -R root:root "$INSTALL_DIR"
    chmod 755 "$INSTALL_DIR"
}

install_python_app() {
    log_info "Installing Python application..."

    # Create virtual environment
    python3 -m venv "$INSTALL_DIR/venv"

    # Install dependencies
    "$INSTALL_DIR/venv/bin/pip" install --upgrade pip
    "$INSTALL_DIR/venv/bin/pip" install flask pycups gunicorn

    # Copy application files
    cp -r "$PROJECT_DIR/src/"* "$INSTALL_DIR/"

    # Copy and set up helper scripts
    mkdir -p "$INSTALL_DIR/scripts"
    for script in set-hostname.sh restart-service.sh configure-avahi.sh enable-printers.sh configure-samba.sh hotplug-printer.sh; do
        if [[ -f "$SCRIPT_DIR/$script" ]]; then
            cp "$SCRIPT_DIR/$script" "$INSTALL_DIR/scripts/"
            chmod +x "$INSTALL_DIR/scripts/$script"
        fi
    done

    # Copy config templates (used by configure-avahi.sh at runtime)
    mkdir -p "$INSTALL_DIR/config/avahi"
    if [[ -f "$PROJECT_DIR/config/avahi/airprint.service.template" ]]; then
        cp "$PROJECT_DIR/config/avahi/airprint.service.template" "$INSTALL_DIR/config/avahi/"
    fi

    # Copy Samba config (used by configure-samba.sh at runtime)
    mkdir -p "$INSTALL_DIR/config/samba"
    if [[ -f "$PROJECT_DIR/config/samba/smb.conf" ]]; then
        cp "$PROJECT_DIR/config/samba/smb.conf" "$INSTALL_DIR/config/samba/"
    fi

    log_info "Python application installed"
}

configure_sudoers() {
    log_info "Configuring sudoers for system management..."

    # Create sudoers entry to allow the web service to change hostname
    SUDOERS_FILE="/etc/sudoers.d/printserver"

    cat > "$SUDOERS_FILE" << 'EOF'
# Allow printserver web service to manage system without password
ALL ALL=(root) NOPASSWD: /opt/printserver/scripts/set-hostname.sh
ALL ALL=(root) NOPASSWD: /opt/printserver/scripts/restart-service.sh
ALL ALL=(root) NOPASSWD: /usr/bin/journalctl
ALL ALL=(root) NOPASSWD: /usr/bin/truncate -s 0 /var/log/cups/error_log
EOF

    chmod 440 "$SUDOERS_FILE"

    # Validate sudoers file
    if visudo -c -f "$SUDOERS_FILE" > /dev/null 2>&1; then
        log_info "Sudoers configuration created successfully"
    else
        log_error "Invalid sudoers configuration, removing..."
        rm -f "$SUDOERS_FILE"
    fi
}

create_default_config() {
    log_info "Creating default configuration..."

    if [[ ! -f "$CONFIG_DIR/config.ini" ]]; then
        cat > "$CONFIG_DIR/config.ini" << 'EOF'
[web]
host = 0.0.0.0
port = 5000
debug = false

[cups]
host = localhost
port = 631

[server]
log_level = INFO
# printer_name = Brother_HL-L2350DW
EOF
        log_info "Default configuration created at $CONFIG_DIR/config.ini"
    else
        log_info "Configuration file already exists, skipping"
    fi
}

configure_cups() {
    log_info "Configuring CUPS..."
    bash "$SCRIPT_DIR/configure-cups.sh"
}

configure_samba() {
    log_info "Configuring Samba for Windows printer sharing..."
    bash "$SCRIPT_DIR/configure-samba.sh"
}

configure_avahi() {
    log_info "Configuring Avahi for AirPrint..."
    bash "$SCRIPT_DIR/configure-avahi.sh"
}

install_udev_rules() {
    log_info "Installing udev rules for printer hotplug..."

    if [[ -f "$PROJECT_DIR/config/udev/99-printer.rules" ]]; then
        cp "$PROJECT_DIR/config/udev/99-printer.rules" /etc/udev/rules.d/
        udevadm control --reload-rules 2>/dev/null || true
        udevadm trigger 2>/dev/null || true
        log_info "udev rules installed"
    else
        log_warn "udev rules file not found, skipping"
    fi
}

install_systemd_service() {
    log_info "Installing systemd service..."

    cp "$PROJECT_DIR/config/systemd/printserver-web.service" /etc/systemd/system/

    # Install printer watchdog timer â€” auto-recovers printers stuck in
    # "stopped" or "failed" state (e.g. after USB sleep or transient error)
    cp "$PROJECT_DIR/config/systemd/printer-watchdog.service" /etc/systemd/system/
    cp "$PROJECT_DIR/config/systemd/printer-watchdog.timer" /etc/systemd/system/
    cp "$SCRIPT_DIR/printer-watchdog.sh" "$INSTALL_DIR/scripts/"
    chmod +x "$INSTALL_DIR/scripts/printer-watchdog.sh"

    # Install printer wake script â€” sends USB reset to wake printer from
    # firmware sleep mode (separate from kernel USB autosuspend)
    cp "$SCRIPT_DIR/wake-printer.sh" "$INSTALL_DIR/scripts/"
    chmod +x "$INSTALL_DIR/scripts/wake-printer.sh"

    # Install USB backend wrapper that wakes the printer BEFORE the real
    # USB backend opens the device.  This is the SOLE wake mechanism.
    # Previous versions also had a CUPS pre-filter and systemd path unit
    # that sent additional USB resets; those caused blank-page loops on
    # Brother printers and have been removed.
    local usb_backend="/usr/lib/cups/backend/usb"
    local usb_real="/usr/lib/cups/backend/usb.real"
    if [[ -f "$usb_backend" && ! -L "$usb_backend" && ! -f "$usb_real" ]]; then
        mv "$usb_backend" "$usb_real"
        log_info "Moved original USB backend to usb.real"
    fi
    cp "$SCRIPT_DIR/usb-printer-wake-backend" "$usb_backend"
    chmod 700 "$usb_backend"
    log_info "USB wake backend wrapper installed"

    # Disable the old printer-wake path unit if it was previously enabled.
    # Wake responsibility now lives exclusively in the backend wrapper.
    # The path unit caused overlapping USB resets â†’ blank page loops.
    systemctl disable --now printer-wake.path 2>/dev/null || true
    systemctl disable --now printer-wake.service 2>/dev/null || true
    # Copy the disabled unit files so systemd doesn't complain about dangling symlinks
    cp "$PROJECT_DIR/config/systemd/printer-wake.path" /etc/systemd/system/
    cp "$PROJECT_DIR/config/systemd/printer-wake.service" /etc/systemd/system/
    log_info "Printer wake path unit disabled (wake handled by backend wrapper)"

    # Remove the old CUPS pre-filter registration if present.
    # The filter caused additional USB resets on top of the backend wrapper.
    local convs_file="/usr/share/cups/mime/printserver-wake.convs"
    if [[ -f "$convs_file" ]]; then
        cp "$PROJECT_DIR/config/cups/printserver-wake.convs" "$convs_file"
        log_info "CUPS wake filter disabled (replaced with empty convs)"
    fi

    systemctl daemon-reload
    systemctl enable printserver-web.service
    systemctl enable cups.service
    systemctl enable avahi-daemon.service
    systemctl enable --now printer-watchdog.timer
    systemctl enable smbd.service nmbd.service 2>/dev/null || true
    systemctl enable wsdd.service 2>/dev/null || true

    # Disable cups-browsed — it discovers REMOTE printers which conflicts
    # with our local USB setup. It creates stale dbus subscriptions that
    # crash the CUPS 2.4.x scheduler ("Scheduler shutting down due to
    # program error"). We only serve a local USB printer, no browsing needed.
    systemctl stop cups-browsed 2>/dev/null || true
    systemctl disable cups-browsed 2>/dev/null || true
    systemctl mask cups-browsed 2>/dev/null || true
    # Clean stale dbus subscriptions left by cups-browsed
    rm -f /var/cache/cups/subscriptions.conf* 2>/dev/null || true
    log_info "cups-browsed disabled (not needed for local USB printer)"

    # Disable CUPS dbus notifier — it spawns dozens of processes on a headless
    # Pi (no desktop to receive notifications) and the accumulated stale
    # subscriptions crash the CUPS 2.4.x scheduler.
    local dbus_notifier="/usr/lib/cups/notifier/dbus"
    if [[ -x "$dbus_notifier" ]]; then
        chmod 000 "$dbus_notifier"
        log_info "CUPS dbus notifier disabled (not needed on headless Pi)"
    fi

    log_info "Systemd services configured"
}

configure_log_limits() {
    log_info "Configuring log retention limits..."

    # journald: enable persistent storage so logs survive reboots/freezes,
    # then cap at 50M to prevent disk fill on small SD cards.
    mkdir -p /var/log/journal
    systemd-tmpfiles --create --prefix /var/log/journal 2>/dev/null || true
    mkdir -p /etc/systemd/journald.conf.d
    cat > /etc/systemd/journald.conf.d/printserver.conf << 'EOF'
[Journal]
Storage=persistent
SystemMaxUse=50M
RuntimeMaxUse=30M
MaxRetentionSec=7day
# Flush RAM buffer to disk every 30s instead of the default 5 minutes.
# The Python app also writes directly to /var/log/printserver/app.log
# (flushed per-line), so this is a secondary safety net for other services.
SyncIntervalSec=30s
EOF
    systemctl restart systemd-journald 2>/dev/null || true

    # CUPS error log rotation
    cat > /etc/logrotate.d/cups-printserver << 'EOF'
/var/log/cups/error_log {
    daily
    rotate 3
    compress
    delaycompress
    missingok
    notifempty
}
EOF

    # Printserver app.log rotation (Python RotatingFileHandler also rotates at
    # 5 MB, but logrotate provides a system-level safety net and ensures
    # old backups are cleaned up even if the service isn't running).
    cat > /etc/logrotate.d/printserver-app << 'EOF'
/var/log/printserver/app.log {
    daily
    rotate 7
    compress
    delaycompress
    missingok
    notifempty
    copytruncate
}
EOF

    log_info "Log limits configured"
}

configure_system_tuning() {
    log_info "Tuning system for low-memory Raspberry Pi..."

    # Reduce swappiness: prefer dropping cache over swapping
    if ! grep -q "vm.swappiness" /etc/sysctl.conf 2>/dev/null; then
        echo "vm.swappiness=10" >> /etc/sysctl.conf
        sysctl -w vm.swappiness=10 2>/dev/null || true
    fi

    # Disable unnecessary services to free memory
    for svc in bluetooth triggerhappy ModemManager; do
        if systemctl is-enabled "$svc" 2>/dev/null | grep -q "enabled"; then
            systemctl disable --now "$svc" 2>/dev/null || true
            log_info "Disabled $svc"
        fi
    done

    # --- WiFi power management: disable power save ---
    # WiFi power-save mode delays mDNS multicast responses, causing slow
    # printer discovery on Windows/iOS (can add 30-60s to "Add Printer").
    configure_wifi_performance

    # --- USB autosuspend: keep printer awake ---
    # Prevents the kernel from suspending the USB printer port, which adds
    # wake-up latency when a print job arrives after idle time.
    configure_usb_power

    log_info "System tuning applied"
}

configure_wifi_performance() {
    log_info "Disabling WiFi power management for faster discovery..."

    # Method 1: NetworkManager dispatcher (persists across reboots)
    local nm_dispatcher="/etc/NetworkManager/dispatcher.d/99-wifi-powersave-off"
    if command -v nmcli &> /dev/null; then
        cat > "$nm_dispatcher" << 'NMEOF'
#!/bin/bash
# Disable WiFi power save so mDNS responses are instant
if [ "$2" = "up" ] && [ "$(nmcli -t -f TYPE con show --active | grep wireless)" ]; then
    iw dev wlan0 set power_save off 2>/dev/null || true
fi
NMEOF
        chmod +x "$nm_dispatcher"
        log_info "Created NetworkManager dispatcher for WiFi power-save"
    fi

    # Method 2: udev rule (works even without NetworkManager)
    local udev_wifi="/etc/udev/rules.d/70-wifi-powersave.rules"
    cat > "$udev_wifi" << 'UDEVEOF'
# Disable WiFi power-save on interface up â€” ensures fast mDNS responses
ACTION=="add", SUBSYSTEM=="net", KERNEL=="wlan*", RUN+="/usr/sbin/iw dev %k set power_save off"
UDEVEOF
    log_info "Created udev rule for WiFi power-save"

    # Method 3: Apply immediately
    if ip link show wlan0 &> /dev/null; then
        iw dev wlan0 set power_save off 2>/dev/null || true
        log_info "WiFi power-save disabled on wlan0"
    fi
}

configure_usb_power() {
    log_info "Disabling USB autosuspend for printers..."

    # Disable USB autosuspend for printer class devices so the printer
    # doesn't go into a low-power state between print jobs.
    local udev_usb="/etc/udev/rules.d/71-usb-printer-power.rules"
    cat > "$udev_usb" << 'USBEOF'
# Keep USB printers awake â€” disable kernel autosuspend for printer class (07)
ACTION=="add", SUBSYSTEM=="usb", ATTR{bInterfaceClass}=="07", TEST=="power/autosuspend", ATTR{power/autosuspend}="-1"
ACTION=="add", SUBSYSTEM=="usb", ATTR{bInterfaceClass}=="07", TEST=="power/control", ATTR{power/control}="on"
USBEOF
    log_info "Created udev rule to keep USB printers awake"

    # Apply to currently connected printers
    for dev in /sys/bus/usb/devices/*/bInterfaceClass; do
        if [[ -f "$dev" ]] && [[ "$(cat "$dev" 2>/dev/null)" == "07" ]]; then
            local parent
            parent=$(dirname "$dev")
            parent=$(dirname "$parent")
            if [[ -f "$parent/power/autosuspend" ]]; then
                echo -1 > "$parent/power/autosuspend" 2>/dev/null || true
            fi
            if [[ -f "$parent/power/control" ]]; then
                echo "on" > "$parent/power/control" 2>/dev/null || true
            fi
            log_info "Disabled autosuspend for connected USB printer"
        fi
    done
}

wait_for_cups() {
    # Poll for CUPS scheduler readiness
    local max_attempts=${1:-10}
    local delay=${2:-2}
    local attempt=1

    while [[ $attempt -le $max_attempts ]]; do
        if lpstat -r 2>/dev/null | grep -q "scheduler is running"; then
            log_info "CUPS scheduler is ready (attempt $attempt)"
            return 0
        fi
        log_info "Waiting for CUPS scheduler (attempt $attempt/$max_attempts)..."
        sleep "$delay"
        ((attempt++))
    done

    log_warn "CUPS scheduler not confirmed ready after $max_attempts attempts"
    return 1
}

start_services() {
    log_info "Starting services..."

    # Clear any previous start-limit failures so systemd allows starting
    systemctl reset-failed printserver-web.service 2>/dev/null || true
    systemctl reset-failed cups.service 2>/dev/null || true

    systemctl start cups

    # Wait for CUPS to actually be ready before starting dependent services
    wait_for_cups 10 2

    systemctl start avahi-daemon
    systemctl start smbd nmbd 2>/dev/null || true
    systemctl start wsdd 2>/dev/null || true
    systemctl start printserver-web

    # Verify with health check (retry a few times â€” gunicorn needs time to bind)
    local attempt=1
    while [[ $attempt -le 5 ]]; do
        if curl -s -o /dev/null -w "%{http_code}" http://localhost:5000/health 2>/dev/null | grep -q "200"; then
            log_info "Web interface is healthy"
            break
        fi
        sleep 2
        ((attempt++))
    done
    if [[ $attempt -gt 5 ]]; then
        log_warn "Web interface may still be starting. Check: systemctl status printserver-web"
    fi

    log_info "Services started"
}

restart_services() {
    log_info "Restarting services to apply updates..."

    # Reload unit files in case the .service file was updated during install
    systemctl daemon-reload

    # Clear any previous start-limit failures so systemd allows restarting.
    # Without this, hitting StartLimitBurst=5 causes systemd to permanently
    # refuse to start the service until the failed state is manually cleared.
    systemctl reset-failed printserver-web.service 2>/dev/null || true
    systemctl reset-failed cups.service 2>/dev/null || true

    # Restart CUPS and wait for it to be ready
    systemctl restart cups
    wait_for_cups 10 2

    # Restart Avahi to apply AirPrint changes
    systemctl restart avahi-daemon
    sleep 1

    # Restart Samba and WSD daemon for Windows sharing/discovery
    systemctl restart smbd nmbd 2>/dev/null || true
    systemctl restart wsdd 2>/dev/null || true
    sleep 1

    # Restart web interface to apply code updates
    systemctl restart printserver-web

    # Verify all services are running
    if systemctl is-active --quiet cups && \
       systemctl is-active --quiet avahi-daemon && \
       systemctl is-active --quiet printserver-web; then
        log_info "All services restarted successfully"
    else
        log_warn "Some services may not have started correctly. Check status with:"
        log_warn "  systemctl status cups avahi-daemon smbd printserver-web"
    fi

    # Verify web interface health (retry a few times â€” gunicorn needs time to bind)
    local attempt=1
    while [[ $attempt -le 5 ]]; do
        if curl -s -o /dev/null -w "%{http_code}" http://localhost:5000/health 2>/dev/null | grep -q "200"; then
            log_info "Web interface health check passed"
            break
        fi
        sleep 2
        ((attempt++))
    done
    if [[ $attempt -gt 5 ]]; then
        log_warn "Web interface health check failed - it may still be starting"
    fi
}

detect_printer() {
    log_info "Detecting USB printers..."

    local max_attempts=5
    local delay=3
    local attempt=1

    # Retry loop: printer USB interface may take time to initialize
    while [[ $attempt -le $max_attempts ]]; do
        if lpinfo -v 2>/dev/null | grep -q "usb://"; then
            PRINTER_URI=$(lpinfo -v 2>/dev/null | grep "usb://" | head -1 | awk '{print $2}')
            log_info "Found USB printer: $PRINTER_URI (attempt $attempt)"

            # Extract printer name from URI
            # e.g. usb://Brother/HL-L2340D%20series?serial=... â†’ Brother_HL-L2340D_series
            PRINTER_NAME=$(echo "$PRINTER_URI" \
                | sed 's|usb://||' \
                | sed 's|%[0-9A-Fa-f]\{2\}| |g' \
                | tr -s '/ ?&=' '_' \
                | sed 's/^_//; s/_$//')

            # Add printer to CUPS.
            # Driver priority: model-specific brlaser > generic PWG Raster > raw.
            # Do NOT use -m everywhere (requires IPP network connection, fails
            # with USB URIs on newer CUPS).
            # Sleep recovery is handled by retry-job, wake-printer.sh, and watchdog.
            if ! lpstat -p "$PRINTER_NAME" > /dev/null 2>&1; then
                log_info "Adding printer '$PRINTER_NAME' to CUPS..."
                local brlaser_ppd
                brlaser_ppd=$(lpinfo -m 2>/dev/null | grep -i "brlaser" | grep -i "$(echo "$PRINTER_NAME" | tr '_' ' ' | awk '{print $NF}')" | head -1 | awk '{print $1}')
                if [[ -n "$brlaser_ppd" ]] && lpadmin -p "$PRINTER_NAME" -E -v "$PRINTER_URI" -m "$brlaser_ppd" 2>/dev/null; then
                    log_info "Printer added with brlaser driver: $brlaser_ppd"
                elif lpadmin -p "$PRINTER_NAME" -E -v "$PRINTER_URI" -m "drv:///cupsfilters.drv/pwgrast.ppd" 2>/dev/null; then
                    log_info "Printer added with PWG Raster driver"
                else
                    log_warn "All drivers failed â€” add printer via CUPS web UI"
                fi
                lpadmin -d "$PRINTER_NAME"  # Set as default
                log_info "Printer set as default"
            else
                log_info "Printer '$PRINTER_NAME' already configured"
            fi

            # Set error policy to retry-job so the printer doesn't get
            # permanently stuck in "failed" state after transient errors
            lpadmin -p "$PRINTER_NAME" -o printer-error-policy=retry-job 2>/dev/null || true

            # Enable printer, accept jobs, and mark as shared for AirPrint/network discovery
            log_info "Configuring printer to accept jobs and enable sharing..."
            cupsenable "$PRINTER_NAME" 2>/dev/null || true
            cupsaccept "$PRINTER_NAME" 2>/dev/null || true
            lpadmin -p "$PRINTER_NAME" -o printer-is-shared=true 2>/dev/null || true
            log_info "Printer configured and ready"
            return 0
        fi

        log_info "No USB printer found (attempt $attempt/$max_attempts), waiting ${delay}s..."
        sleep "$delay"
        ((attempt++))
    done

    log_warn "No USB printer detected after $max_attempts attempts."
    log_warn "Connect your printer and run:"
    log_warn "  sudo lpinfo -v  # to list available printers"
    log_warn "  sudo lpadmin -p PrinterName -E -v usb://... -m drv:///brlaser.drv/MODEL.ppd"
    log_warn "  sudo cupsenable PrinterName && sudo cupsaccept PrinterName"
}

enable_all_printers() {
    log_info "Enabling all configured printers..."

    # Get list of all printers and enable them
    lpstat -p 2>/dev/null | awk '{print $2}' | while read -r printer; do
        if [[ -n "$printer" ]]; then
            log_info "Enabling printer: $printer"
            cupsenable "$printer" 2>/dev/null || true
            cupsaccept "$printer" 2>/dev/null || true
            lpadmin -p "$printer" -o printer-is-shared=true 2>/dev/null || true
        fi
    done
}

print_summary() {
    echo
    echo "========================================"
    if [[ "$IS_UPDATE" == "true" ]]; then
        echo "  Print Server Update Complete!"
    else
        echo "  Print Server Installation Complete!"
    fi
    echo "========================================"
    echo
    PI_IP=$(hostname -I | awk '{print $1}')
    log_info "Web interface: http://${PI_IP}:5000"
    log_info "CUPS admin:    http://${PI_IP}:631"
    echo
    log_info "â”€â”€ Windows printing â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€"
    log_info "  Recommended (IPP, no password needed):"
    log_info "    Settings â†’ Printers â†’ Add â†’ 'not listed' â†’ 'by name' â†’"
    log_info "    http://${PI_IP}:631/printers/<PrinterName>"
    echo
    log_info "  SMB path (File Explorer): \\\\${PI_IP}"
    log_info "    Username: printuser"
    log_info "    Password: printserver  (change: sudo smbpasswd printuser)"
    log_info "â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€"
    echo
    log_info "To check status: sudo systemctl status printserver-web"
    log_info "To view logs:    sudo journalctl -u printserver-web -f"
    echo
    if lpstat -p > /dev/null 2>&1; then
        log_info "Configured printers:"
        lpstat -p
    fi
    echo
    if [[ "$IS_UPDATE" == "true" ]]; then
        log_info "All services have been restarted to apply updates"
        log_info "Your print server is now running the latest version"
    fi
    echo
}

fix_hosts_file() {
    log_info "Ensuring /etc/hosts is configured correctly..."

    CURRENT_HOSTNAME=$(hostname)

    # Check if 127.0.1.1 entry exists for current hostname
    if ! grep -q "127.0.1.1.*$CURRENT_HOSTNAME" /etc/hosts; then
        # Remove any existing 127.0.1.1 line and add correct one
        sed -i '/127.0.1.1/d' /etc/hosts
        echo -e "127.0.1.1\t$CURRENT_HOSTNAME" >> /etc/hosts
        log_info "Added hostname entry to /etc/hosts"
    else
        log_info "/etc/hosts already configured correctly"
    fi
}

# Main installation flow
main() {
    echo "========================================"
    echo "  Raspberry Pi Print Server Installer"
    echo "========================================"
    echo

    check_root
    check_raspberry_pi

    # Check if this is an update (service already exists)
    IS_UPDATE=false
    if systemctl is-enabled --quiet printserver-web 2>/dev/null; then
        IS_UPDATE=true
        log_info "Existing installation detected - performing update"
    else
        log_info "Performing fresh installation"
    fi

    install_system_packages
    create_directories
    install_python_app
    create_default_config
    configure_sudoers
    fix_hosts_file
    configure_cups
    configure_samba
    install_udev_rules
    install_systemd_service
    configure_log_limits
    configure_system_tuning

    # Start or restart services
    if [[ "$IS_UPDATE" == "true" ]]; then
        restart_services
    else
        start_services
    fi

    # Always detect and configure printers (both fresh install and update).
    # On update, existing queues are preserved; detect_printer only adds
    # if the queue doesn't already exist.
    detect_printer

    # Enable sharing (may have failed during configure_cups if CUPS wasn't
    # ready yet; now CUPS is running so retry).
    # This MUST run BEFORE enable_all_printers because cupsctl can trigger
    # a CUPS reload that resets printer acceptance state.
    cupsctl --share-printers --remote-any --no-remote-admin 2>/dev/null || true

    # cupsctl --remote-any can rewrite "Listen *:631" to "Port 631".
    # Restore it so the printer is accessible from the network.
    if grep -q "^Port 631" /etc/cups/cupsd.conf && ! grep -q "^Listen \*:631" /etc/cups/cupsd.conf; then
        sed -i 's/^Port 631/Listen *:631/' /etc/cups/cupsd.conf
        log_info "Restored Listen *:631 after cupsctl"
        systemctl restart cups 2>/dev/null || true
        sleep 2
    fi

    # Configure Avahi AFTER printers are detected so service files
    # are generated for any printer already connected at install time.
    configure_avahi

    # Enable all printers as the LAST step — after cupsctl and avahi config,
    # which can both trigger CUPS reloads that reset acceptance state.
    enable_all_printers

    # Final safety: explicitly accept jobs on all printers one more time.
    # Belt-and-suspenders because some CUPS versions reset acceptance on reload.
    sleep 2
    lpstat -p 2>/dev/null | awk '{print $2}' | while read -r p; do
        [[ -n "$p" ]] && cupsaccept "$p" 2>/dev/null && cupsenable "$p" 2>/dev/null
    done || true

    print_summary
}

main "$@"
