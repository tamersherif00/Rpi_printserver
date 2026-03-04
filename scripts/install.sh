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

    # ── Mandatory packages ────────────────────────────────────────────────────
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

    # ── Optional system packages ──────────────────────────────────────────────
    # Package names and availability vary across Debian/Raspbian releases
    # (e.g. cups-browsed was split from cups-filters in Debian Trixie+).
    # Install each individually so a missing package doesn't abort the script.
    for pkg in cups-filters cups-browsed libcups2-dev; do
        if apt-get install -y "$pkg" 2>/dev/null; then
            log_info "  installed: $pkg"
        else
            log_warn "$pkg not available in current repos — skipping (non-fatal)"
        fi
    done

    # ── wsdd: Windows 10/11 auto-discovery via WS-Discovery ──────────────────
    # Strategy:
    #   1. Try apt  (available on Bullseye/Bookworm; removed from Trixie+).
    #   2. Download the standalone Python script from the upstream GitHub repo.
    #      wsdd is NOT published to PyPI — pip install wsdd will always fail.
    #   3. Warn and provide manual-add instructions if both methods fail.
    if apt-get install -y wsdd 2>/dev/null; then
        log_info "wsdd installed from apt"
    else
        log_info "apt wsdd unavailable — downloading from GitHub (christgau/wsdd)..."
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

    # ── Optional printer drivers ──────────────────────────────────────────────
    log_info "Installing printer drivers (where available)..."
    for pkg in printer-driver-brlaser printer-driver-cups-pdf printer-driver-gutenprint; do
        if apt-cache show "$pkg" > /dev/null 2>&1; then
            apt-get install -y "$pkg" && log_info "  installed: $pkg"
        else
            log_warn "  $pkg not available in current repos — skipping"
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
    for script in set-hostname.sh restart-service.sh configure-avahi.sh enable-printers.sh configure-samba.sh; do
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

    systemctl daemon-reload
    systemctl enable printserver-web.service
    systemctl enable cups.service
    systemctl enable avahi-daemon.service
    systemctl enable smbd.service nmbd.service 2>/dev/null || true
    systemctl enable wsdd.service 2>/dev/null || true

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

    log_info "System tuning applied"
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

    systemctl start cups

    # Wait for CUPS to actually be ready before starting dependent services
    wait_for_cups 10 2

    systemctl start avahi-daemon
    systemctl start smbd nmbd 2>/dev/null || true
    systemctl start wsdd 2>/dev/null || true
    systemctl start printserver-web

    # Verify with health check
    sleep 3
    if curl -s -o /dev/null -w "%{http_code}" http://localhost:5000/health 2>/dev/null | grep -q "200"; then
        log_info "Web interface is healthy"
    else
        log_warn "Web interface may still be starting. Check: systemctl status printserver-web"
    fi

    log_info "Services started"
}

restart_services() {
    log_info "Restarting services to apply updates..."

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
    sleep 2

    # Verify all services are running
    if systemctl is-active --quiet cups && \
       systemctl is-active --quiet avahi-daemon && \
       systemctl is-active --quiet printserver-web; then
        log_info "All services restarted successfully"
    else
        log_warn "Some services may not have started correctly. Check status with:"
        log_warn "  systemctl status cups avahi-daemon smbd printserver-web"
    fi

    # Verify web interface health
    if curl -s -o /dev/null -w "%{http_code}" http://localhost:5000/health 2>/dev/null | grep -q "200"; then
        log_info "Web interface health check passed"
    else
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
            PRINTER_NAME=$(echo "$PRINTER_URI" | sed 's|usb://||' | tr '/' '_' | tr ' ' '_')

            # Add printer to CUPS
            if ! lpstat -p "$PRINTER_NAME" > /dev/null 2>&1; then
                log_info "Adding printer '$PRINTER_NAME' to CUPS..."
                lpadmin -p "$PRINTER_NAME" -E -v "$PRINTER_URI" -m everywhere
                lpadmin -d "$PRINTER_NAME"  # Set as default
                log_info "Printer added and set as default"
            else
                log_info "Printer '$PRINTER_NAME' already configured"
            fi

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
    log_warn "  sudo lpadmin -p PrinterName -E -v usb://... -m everywhere"
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
    log_info "── Windows printing ─────────────────────────────────────────"
    log_info "  Recommended (IPP, no password needed):"
    log_info "    Settings → Printers → Add → 'not listed' → 'by name' →"
    log_info "    http://${PI_IP}:631/printers/<PrinterName>"
    echo
    log_info "  SMB path (File Explorer): \\\\${PI_IP}"
    log_info "    Username: printuser"
    log_info "    Password: printserver  (change: sudo smbpasswd printuser)"
    log_info "─────────────────────────────────────────────────────────────"
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

    # If updating, restart services; otherwise start them fresh
    if [[ "$IS_UPDATE" == "true" ]]; then
        restart_services
    else
        start_services
        detect_printer
        enable_all_printers
    fi

    # Configure Avahi AFTER printers are detected so service files
    # are generated for any printer already connected at install time.
    # On future hotplug events, udev triggers this script automatically.
    configure_avahi

    print_summary
}

main "$@"
