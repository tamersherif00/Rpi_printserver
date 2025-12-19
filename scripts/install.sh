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

    log_info "Installing required packages..."
    apt-get install -y \
        cups \
        cups-filters \
        cups-browsed \
        avahi-daemon \
        avahi-utils \
        python3 \
        python3-pip \
        python3-venv \
        python3-cups \
        libcups2-dev \
        samba \
        wireless-tools

    # Install Brother printer drivers
    log_info "Installing Brother printer drivers..."

    # brlaser - open source driver for many Brother laser printers
    if apt-cache show printer-driver-brlaser > /dev/null 2>&1; then
        apt-get install -y printer-driver-brlaser
        log_info "Installed brlaser driver (HL-L2300, HL-L2340, HL-L2360, DCP-L2500, etc.)"
    fi

    # Brother's official CUPS wrapper (for inkjet and some lasers)
    if apt-cache show printer-driver-cups-pdf > /dev/null 2>&1; then
        apt-get install -y printer-driver-cups-pdf
    fi

    # Gutenprint - additional printer support
    if apt-cache show printer-driver-gutenprint > /dev/null 2>&1; then
        apt-get install -y printer-driver-gutenprint
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
    "$INSTALL_DIR/venv/bin/pip" install flask pycups

    # Copy application files
    cp -r "$PROJECT_DIR/src/"* "$INSTALL_DIR/"

    log_info "Python application installed"
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

configure_avahi() {
    log_info "Configuring Avahi for AirPrint..."
    bash "$SCRIPT_DIR/configure-avahi.sh"
}

install_systemd_service() {
    log_info "Installing systemd service..."

    cp "$PROJECT_DIR/config/systemd/printserver-web.service" /etc/systemd/system/

    systemctl daemon-reload
    systemctl enable printserver-web.service
    systemctl enable cups.service
    systemctl enable avahi-daemon.service

    log_info "Systemd services configured"
}

start_services() {
    log_info "Starting services..."

    systemctl start cups
    systemctl start avahi-daemon
    systemctl start printserver-web

    log_info "Services started"
}

detect_printer() {
    log_info "Detecting USB printers..."

    # Wait for CUPS to be ready
    sleep 2

    # Check for USB printers
    if lpinfo -v 2>/dev/null | grep -q "usb://"; then
        PRINTER_URI=$(lpinfo -v 2>/dev/null | grep "usb://" | head -1 | awk '{print $2}')
        log_info "Found USB printer: $PRINTER_URI"

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
    else
        log_warn "No USB printer detected. Please connect your printer and run:"
        log_warn "  sudo lpinfo -v  # to list available printers"
        log_warn "  sudo lpadmin -p PrinterName -E -v usb://... -m everywhere"
    fi
}

print_summary() {
    echo
    echo "========================================"
    echo "  Print Server Installation Complete!"
    echo "========================================"
    echo
    log_info "Web interface: http://$(hostname -I | awk '{print $1}'):5000"
    log_info "CUPS admin:    http://$(hostname -I | awk '{print $1}'):631"
    echo
    log_info "To check status: sudo systemctl status printserver-web"
    log_info "To view logs:    sudo journalctl -u printserver-web -f"
    echo
    if lpstat -p > /dev/null 2>&1; then
        log_info "Configured printers:"
        lpstat -p
    fi
    echo
}

# Main installation flow
main() {
    echo "========================================"
    echo "  Raspberry Pi Print Server Installer"
    echo "========================================"
    echo

    check_root
    check_raspberry_pi

    install_system_packages
    create_directories
    install_python_app
    create_default_config
    configure_cups
    configure_avahi
    install_systemd_service
    start_services
    detect_printer
    print_summary
}

main "$@"
