#!/bin/bash
# Avahi Configuration Script
# Configures Avahi for AirPrint and printer discovery.
# Designed to be called both at install time and dynamically by udev
# when printers are plugged/unplugged. Generates one Avahi service file
# per CUPS printer, removes stale ones, and reloads Avahi.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
AVAHI_SERVICES_DIR="/etc/avahi/services"

# Use a lock to prevent concurrent runs (udev can fire multiple events)
LOCK_FILE="/tmp/configure-avahi.lock"

log_info() {
    echo "[INFO] $1"
    logger -t configure-avahi "[INFO] $1" 2>/dev/null || true
}

log_warn() {
    echo "[WARN] $1"
    logger -t configure-avahi "[WARN] $1" 2>/dev/null || true
}

log_error() {
    echo "[ERROR] $1"
    logger -t configure-avahi "[ERROR] $1" 2>/dev/null || true
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

    # Helper: set a key=value in the config, adding it under [server] if absent
    set_avahi_option() {
        local key="$1"
        local value="$2"
        if grep -q "^${key}=" "$AVAHI_CONFIG"; then
            sed -i "s|^${key}=.*|${key}=${value}|" "$AVAHI_CONFIG"
        else
            # Append under [server] section if it exists, else at end of file
            if grep -q "^\[server\]" "$AVAHI_CONFIG"; then
                sed -i "/^\[server\]/a ${key}=${value}" "$AVAHI_CONFIG"
            else
                echo "${key}=${value}" >> "$AVAHI_CONFIG"
            fi
        fi
    }

    # Ensure Avahi is configured for local network discovery
    if [[ -f "$AVAHI_CONFIG" ]]; then
        set_avahi_option "use-ipv4" "yes"
        set_avahi_option "disable-publishing" "no"
        set_avahi_option "publish-workstation" "yes"
        set_avahi_option "publish-addresses" "yes"

        log_info "Avahi daemon configured"
    else
        log_warn "Avahi config not found at $AVAHI_CONFIG"
    fi
}

wait_for_cups() {
    # After a USB hotplug event, CUPS needs time to restart and register
    # the new printer. Poll until CUPS is ready or timeout.
    local max_attempts=${1:-10}
    local delay=${2:-2}
    local attempt=1

    while [[ $attempt -le $max_attempts ]]; do
        if lpstat -r 2>/dev/null | grep -q "scheduler is running"; then
            return 0
        fi
        sleep "$delay"
        ((attempt++))
    done

    log_warn "CUPS scheduler not ready after $((max_attempts * delay))s"
    return 1
}

generate_airprint_service() {
    local printer_name="$1"
    local printer_info="$2"
    local printer_location="$3"

    log_info "Generating AirPrint service for: $printer_name"

    local hostname
    hostname=$(hostname)

    local service_file="$AVAHI_SERVICES_DIR/AirPrint-${printer_name}.service"

    # Try template from deployed location, then repo location
    local template=""
    for candidate in \
        "$PROJECT_DIR/config/avahi/airprint.service.template" \
        "/opt/printserver/config/avahi/airprint.service.template"; do
        if [[ -f "$candidate" ]]; then
            template="$candidate"
            break
        fi
    done

    if [[ -n "$template" ]]; then
        log_info "Using AirPrint service template..."
        sed -e "s|{{PRINTER_NAME}}|$printer_name|g" \
            -e "s|{{PRINTER_INFO}}|$printer_info|g" \
            -e "s|{{PRINTER_LOCATION}}|$printer_location|g" \
            -e "s|{{HOSTNAME}}|$hostname|g" \
            "$template" > "$service_file"
    else
        log_info "Generating AirPrint service file (no template found)..."
        cat > "$service_file" << EOF
<?xml version="1.0" standalone='no'?>
<!DOCTYPE service-group SYSTEM "avahi-service.dtd">
<service-group>
  <name replace-wildcards="yes">$printer_info @ %h</name>

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

sync_airprint_services() {
    # Synchronize Avahi service files with the current set of CUPS printers.
    # Creates files for new printers, removes files for printers that are gone.

    log_info "Syncing AirPrint services with CUPS printers..."

    # Wait for CUPS to be ready (important after hotplug-triggered CUPS restart)
    wait_for_cups 10 2 || true

    # Get current CUPS printers (skip the virtual PDF printer)
    local printers
    printers=$(lpstat -p 2>/dev/null | awk '{print $2}' | grep -v '^PDF$' || echo "")

    if [[ -z "$printers" ]]; then
        log_info "No physical printers in CUPS. Removing all AirPrint service files."
        rm -f "$AVAHI_SERVICES_DIR"/AirPrint-*.service 2>/dev/null || true
        return 0
    fi

    # Build set of expected service file names
    local expected_files=()
    while IFS= read -r printer; do
        [[ -z "$printer" ]] && continue
        expected_files+=("AirPrint-${printer}.service")

        # Always regenerate so stale or incorrect files are replaced
        local service_file="$AVAHI_SERVICES_DIR/AirPrint-${printer}.service"
        local printer_info
        printer_info=$(lpstat -l -p "$printer" 2>/dev/null | grep -oP 'Description: \K.+' || echo "$printer")
        local printer_location
        printer_location=$(lpoptions -p "$printer" 2>/dev/null | grep -oP 'printer-location=\K[^,]+' || echo "")

        generate_airprint_service "$printer" "$printer_info" "$printer_location"
    done <<< "$printers"

    # Remove stale service files for printers that no longer exist in CUPS
    for existing_file in "$AVAHI_SERVICES_DIR"/AirPrint-*.service; do
        [[ ! -f "$existing_file" ]] && continue
        local basename
        basename=$(basename "$existing_file")
        local found=false
        for expected in "${expected_files[@]}"; do
            if [[ "$basename" == "$expected" ]]; then
                found=true
                break
            fi
        done
        if [[ "$found" == "false" ]]; then
            log_info "Removing stale AirPrint service: $basename"
            rm -f "$existing_file"
        fi
    done
}

reload_avahi() {
    # Avahi watches /etc/avahi/services/ for changes and auto-reloads.
    # A SIGHUP ensures it picks up changes immediately.
    log_info "Reloading Avahi daemon..."

    if systemctl is-active avahi-daemon > /dev/null 2>&1; then
        kill -HUP "$(pidof avahi-daemon 2>/dev/null | awk '{print $1}')" 2>/dev/null || \
            systemctl reload avahi-daemon 2>/dev/null || \
            systemctl restart avahi-daemon
    else
        systemctl start avahi-daemon
    fi

    sleep 1

    if systemctl is-active avahi-daemon > /dev/null 2>&1; then
        log_info "Avahi daemon is running"
    else
        log_warn "Avahi daemon may not have started correctly"
    fi
}

verify_services() {
    log_info "Verifying published services..."

    if command -v avahi-browse &> /dev/null; then
        log_info "Published AirPrint services:"
        avahi-browse -t _ipp._tcp 2>/dev/null || true
    fi
}

main() {
    # Acquire lock (non-blocking). If another instance is running, exit
    # silently — it will pick up the same CUPS state.
    exec 9>"$LOCK_FILE"
    if ! flock -n 9; then
        log_info "Another instance is already running, skipping."
        exit 0
    fi

    log_info "Starting Avahi configuration..."

    check_avahi_installed
    configure_avahi_daemon
    sync_airprint_services
    reload_avahi
    verify_services

    log_info "Avahi configuration complete"
}

# Run if called directly (not sourced)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
