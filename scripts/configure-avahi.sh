#!/bin/bash
# Avahi Configuration Script
# Configures Avahi for AirPrint and printer discovery

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
AVAHI_SERVICES_DIR="/etc/avahi/services"

log_info() {
    echo "[INFO] $1"
}

log_warn() {
    echo "[WARN] $1"
}

log_error() {
    echo "[ERROR] $1"
}

check_avahi_installed() {
    if ! command -v avahi-daemon &> /dev/null; then
        log_error "Avahi is not installed. Run install.sh first."
        exit 1
    fi
}

configure_avahi_daemon() {
    log_info "Configuring Avahi daemon..."

    AVAHI_CONFIG="/etc/avahi/avahi-daemon.conf"

    # Ensure Avahi is configured for local network discovery
    if [[ -f "$AVAHI_CONFIG" ]]; then
        # Enable IPv4
        if grep -q "^use-ipv4=" "$AVAHI_CONFIG"; then
            sed -i 's/^use-ipv4=.*/use-ipv4=yes/' "$AVAHI_CONFIG"
        fi

        # Enable publishing
        if grep -q "^disable-publishing=" "$AVAHI_CONFIG"; then
            sed -i 's/^disable-publishing=.*/disable-publishing=no/' "$AVAHI_CONFIG"
        fi

        # Allow interfaces (use all by default)
        if grep -q "^#allow-interfaces=" "$AVAHI_CONFIG"; then
            # Leave commented to allow all interfaces
            :
        fi

        log_info "Avahi daemon configured"
    else
        log_warn "Avahi config not found at $AVAHI_CONFIG"
    fi
}

get_printer_info() {
    # Get the first available printer from CUPS
    PRINTER_NAME=$(lpstat -p 2>/dev/null | head -1 | awk '{print $2}' || echo "")

    if [[ -z "$PRINTER_NAME" ]]; then
        log_warn "No printer found in CUPS. AirPrint service will use placeholder."
        PRINTER_NAME="Printer"
    fi

    # Get printer URI
    PRINTER_URI=$(lpstat -v "$PRINTER_NAME" 2>/dev/null | awk '{print $4}' || echo "")

    # Get printer location (default to empty)
    PRINTER_LOCATION=$(lpoptions -p "$PRINTER_NAME" 2>/dev/null | grep -oP 'printer-location=\K[^,]+' || echo "")

    # Get printer make/model
    PRINTER_INFO=$(lpstat -l -p "$PRINTER_NAME" 2>/dev/null | grep -oP 'Description: \K.+' || echo "$PRINTER_NAME")

    echo "$PRINTER_NAME|$PRINTER_URI|$PRINTER_LOCATION|$PRINTER_INFO"
}

generate_airprint_service() {
    local printer_name="$1"
    local printer_info="$2"
    local printer_location="$3"

    log_info "Generating AirPrint service for: $printer_name"

    # Get hostname
    local hostname
    hostname=$(hostname)

    # Get IP address (prefer wlan0, fallback to eth0)
    local ip_address
    ip_address=$(ip -4 addr show wlan0 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' || \
                 ip -4 addr show eth0 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' || \
                 echo "")

    # Create service file
    local service_file="$AVAHI_SERVICES_DIR/AirPrint-${printer_name}.service"

    # Use template if available, otherwise generate
    if [[ -f "$PROJECT_DIR/config/avahi/airprint.service.template" ]]; then
        log_info "Using AirPrint service template..."

        # Copy and customize template
        sed -e "s|{{PRINTER_NAME}}|$printer_name|g" \
            -e "s|{{PRINTER_INFO}}|$printer_info|g" \
            -e "s|{{PRINTER_LOCATION}}|$printer_location|g" \
            -e "s|{{HOSTNAME}}|$hostname|g" \
            "$PROJECT_DIR/config/avahi/airprint.service.template" > "$service_file"
    else
        log_info "Generating AirPrint service file..."

        cat > "$service_file" << EOF
<?xml version="1.0" standalone='no'?>
<!DOCTYPE service-group SYSTEM "avahi-service.dtd">
<service-group>
  <name replace-wildcards="yes">$printer_info @ %h</name>

  <!-- AirPrint service -->
  <service>
    <type>_ipp._tcp</type>
    <subtype>_universal._sub._ipp._tcp</subtype>
    <port>631</port>
    <txt-record>txtvers=1</txt-record>
    <txt-record>qtotal=1</txt-record>
    <txt-record>rp=printers/$printer_name</txt-record>
    <txt-record>ty=$printer_info</txt-record>
    <txt-record>adminurl=http://$hostname.local:631/printers/$printer_name</txt-record>
    <txt-record>note=$printer_location</txt-record>
    <txt-record>priority=0</txt-record>
    <txt-record>product=(GPL Ghostscript)</txt-record>
    <txt-record>pdl=application/octet-stream,application/pdf,application/postscript,image/gif,image/jpeg,image/png,image/tiff,image/urf,application/vnd.cups-banner,application/vnd.cups-pdf,application/vnd.cups-postscript,application/vnd.cups-raw</txt-record>
    <txt-record>URF=W8,SRGB24,CP1,RS300</txt-record>
    <txt-record>Color=T</txt-record>
    <txt-record>Duplex=F</txt-record>
    <txt-record>Copies=T</txt-record>
    <txt-record>Collate=T</txt-record>
    <txt-record>Punch=F</txt-record>
    <txt-record>Bind=F</txt-record>
    <txt-record>Sort=F</txt-record>
    <txt-record>Scan=F</txt-record>
    <txt-record>Fax=F</txt-record>
    <txt-record>TLS=1.2</txt-record>
  </service>

  <!-- IPP Everywhere (for Android/Chrome) -->
  <service>
    <type>_ipps._tcp</type>
    <subtype>_universal._sub._ipps._tcp</subtype>
    <port>631</port>
    <txt-record>txtvers=1</txt-record>
    <txt-record>qtotal=1</txt-record>
    <txt-record>rp=printers/$printer_name</txt-record>
    <txt-record>ty=$printer_info</txt-record>
    <txt-record>adminurl=https://$hostname.local:631/printers/$printer_name</txt-record>
    <txt-record>note=$printer_location</txt-record>
    <txt-record>pdl=application/octet-stream,application/pdf,application/postscript,image/gif,image/jpeg,image/png,image/tiff,image/urf,application/vnd.cups-banner,application/vnd.cups-pdf,application/vnd.cups-postscript,application/vnd.cups-raw</txt-record>
    <txt-record>URF=W8,SRGB24,CP1,RS300</txt-record>
    <txt-record>TLS=1.2</txt-record>
  </service>
</service-group>
EOF
    fi

    log_info "Created AirPrint service: $service_file"
}

remove_old_services() {
    log_info "Removing old AirPrint service files..."

    # Remove any existing AirPrint service files
    rm -f "$AVAHI_SERVICES_DIR"/AirPrint-*.service 2>/dev/null || true
}

create_airprint_services() {
    log_info "Creating AirPrint services for all printers..."

    # Get list of printers
    local printers
    printers=$(lpstat -p 2>/dev/null | awk '{print $2}' || echo "")

    if [[ -z "$printers" ]]; then
        log_warn "No printers found in CUPS. Skipping AirPrint service creation."
        log_info "Add a printer to CUPS and re-run this script."
        return 0
    fi

    remove_old_services

    # Create service for each printer
    while IFS= read -r printer; do
        if [[ -n "$printer" ]]; then
            # Get printer details
            local printer_info
            printer_info=$(lpstat -l -p "$printer" 2>/dev/null | grep -oP 'Description: \K.+' || echo "$printer")

            local printer_location
            printer_location=$(lpoptions -p "$printer" 2>/dev/null | grep -oP 'printer-location=\K[^,]+' || echo "")

            generate_airprint_service "$printer" "$printer_info" "$printer_location"
        fi
    done <<< "$printers"
}

restart_avahi() {
    log_info "Restarting Avahi daemon..."

    systemctl restart avahi-daemon

    sleep 2

    if systemctl is-active avahi-daemon > /dev/null 2>&1; then
        log_info "Avahi daemon is running"
    else
        log_warn "Avahi daemon may not have started correctly"
        systemctl status avahi-daemon
    fi
}

verify_services() {
    log_info "Verifying published services..."

    # List published services
    if command -v avahi-browse &> /dev/null; then
        log_info "Published AirPrint services:"
        avahi-browse -t _ipp._tcp 2>/dev/null || true
    fi
}

main() {
    log_info "Starting Avahi configuration..."

    check_avahi_installed
    configure_avahi_daemon
    create_airprint_services
    restart_avahi
    verify_services

    log_info "Avahi configuration complete"
}

# Run if called directly (not sourced)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
