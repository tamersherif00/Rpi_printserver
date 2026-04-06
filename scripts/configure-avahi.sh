#!/bin/bash
# Avahi Configuration Script
# Configures Avahi for AirPrint and printer discovery.
# Generates explicit Avahi service files for each shared CUPS printer
# (CUPS's built-in dnssd advertising is unreliable with USB printers).
# Windows, iOS, and Android discover the printer via these mDNS records.

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

    # Helper: set key=value under a specific section.
    # Each key must go in its correct section per avahi-daemon.conf(5):
    #   [server]  - use-ipv4, use-ipv6, ...
    #   [publish] - disable-publishing, publish-addresses, publish-workstation, ...
    set_avahi_option() {
        local section="$1"
        local key="$2"
        local value="$3"
        if grep -q "^${key}=" "$AVAHI_CONFIG"; then
            # Key already exists somewhere - update it in place
            sed -i "s|^${key}=.*|${key}=${value}|" "$AVAHI_CONFIG"
        else
            # Add it directly after the section header
            if grep -q "^\[${section}\]" "$AVAHI_CONFIG"; then
                sed -i "/^\[${section}\]/a ${key}=${value}" "$AVAHI_CONFIG"
            else
                # Section missing entirely - append section + key
                printf '\n[%s]\n%s=%s\n' "$section" "$key" "$value" >> "$AVAHI_CONFIG"
            fi
        fi
    }

    # Ensure Avahi is configured for local network discovery
    if [[ -f "$AVAHI_CONFIG" ]]; then
        # [server] keys
        set_avahi_option "server"  "use-ipv4"           "yes"
        # [publish] keys
        set_avahi_option "publish" "disable-publishing"  "no"
        set_avahi_option "publish" "publish-workstation" "yes"
        set_avahi_option "publish" "publish-addresses"   "yes"

        # --- Performance tuning for faster discovery ---

        # Enable reflector so mDNS works across subnets/VLANs
        if grep -q "^#enable-reflector=" "$AVAHI_CONFIG"; then
            sed -i 's/^#enable-reflector=.*/enable-reflector=yes/' "$AVAHI_CONFIG"
        elif grep -q "^enable-reflector=" "$AVAHI_CONFIG"; then
            sed -i 's/^enable-reflector=.*/enable-reflector=yes/' "$AVAHI_CONFIG"
        fi

        # Cache entries for faster repeated lookups
        if grep -q "^cache-entries-max=" "$AVAHI_CONFIG"; then
            sed -i 's/^cache-entries-max=.*/cache-entries-max=256/' "$AVAHI_CONFIG"
        elif grep -q "^#cache-entries-max=" "$AVAHI_CONFIG"; then
            sed -i 's/^#cache-entries-max=.*/cache-entries-max=256/' "$AVAHI_CONFIG"
        fi

        # Disable IPv6 if not needed — reduces multicast traffic and speeds up
        # discovery on IPv4-only networks (most home networks)
        if grep -q "^use-ipv6=" "$AVAHI_CONFIG"; then
            sed -i 's/^use-ipv6=.*/use-ipv6=no/' "$AVAHI_CONFIG"
        elif grep -q "^#use-ipv6=" "$AVAHI_CONFIG"; then
            sed -i 's/^#use-ipv6=.*/use-ipv6=no/' "$AVAHI_CONFIG"
        fi

        log_info "Avahi daemon configured with performance tuning"
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

generate_printer_service_files() {
    # Generate explicit Avahi service files for each shared CUPS printer.
    #
    # CUPS's built-in dnssd advertising (BrowseLocalProtocols dnssd) is
    # unreliable with USB printers — it often fails silently. Writing
    # explicit Avahi service files is 100% reliable for Windows/iOS/Android.

    # Clean up old files first
    rm -f "$AVAHI_SERVICES_DIR"/printer-*.service 2>/dev/null
    rm -f "$AVAHI_SERVICES_DIR"/AirPrint-*.service 2>/dev/null

    local count=0
    while IFS= read -r printer; do
        [[ -z "$printer" ]] && continue

        local dev_uri
        dev_uri=$(lpstat -v "$printer" 2>/dev/null | awk '{print $NF}')
        if [[ "$dev_uri" == *"/dev/null"* ]]; then
            continue
        fi

        local description
        description=$(lpoptions -p "$printer" 2>/dev/null | grep -oP 'printer-info=\K[^ ]*' || echo "$printer")

        cat > "$AVAHI_SERVICES_DIR/printer-${printer}.service" << SVCEOF
<?xml version="1.0" standalone='no'?>
<!DOCTYPE service-group SYSTEM "avahi-service.dtd">
<service-group>
  <name replace-wildcards="yes">$printer @ %h</name>
  <service>
    <type>_ipp._tcp</type>
    <subtype>_universal._sub._ipp._tcp</subtype>
    <port>631</port>
    <txt-record>txtvers=1</txt-record>
    <txt-record>qtotal=1</txt-record>
    <txt-record>rp=printers/$printer</txt-record>
    <txt-record>ty=$description</txt-record>
    <txt-record>pdl=application/octet-stream,application/pdf,image/pwg-raster,image/urf</txt-record>
    <txt-record>URF=W8,SRGB24,CP1,RS600</txt-record>
    <txt-record>printer-state=3</txt-record>
    <txt-record>printer-type=0x801046</txt-record>
  </service>
</service-group>
SVCEOF
        ((count++))
        log_info "Created Avahi service file for: $printer"
    done < <(lpstat -p 2>/dev/null | awk '{print $2}')

    if [[ $count -eq 0 ]]; then
        log_warn "No printers found to advertise via Avahi"
    else
        log_info "Created $count Avahi service file(s)"
    fi
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
    wait_for_cups 10 2 || true
    generate_printer_service_files
    reload_avahi
    verify_services

    log_info "Avahi configuration complete"
}

# Run if called directly (not sourced)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
