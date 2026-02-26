#!/bin/bash
# Avahi Configuration Script
# Configures Avahi for AirPrint and printer discovery.
# CUPS advertises _ipp._tcp/_ipps._tcp natively via its dnssd integration;
# this script ensures Avahi is correctly configured and removes any legacy
# custom service files that would cause name collisions.

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

remove_custom_airprint_services() {
    # CUPS advertises _ipp._tcp and _ipps._tcp natively via its dnssd integration
    # (BrowseLocalProtocols dnssd in cupsd.conf). Custom service files in
    # /etc/avahi/services/ duplicate those registrations and cause "Local name
    # collision" errors that make Avahi drop the entire service group.
    # Remove any leftover custom files so CUPS is the sole advertiser.

    local count
    count=$(find "$AVAHI_SERVICES_DIR" -maxdepth 1 -name 'AirPrint-*.service' 2>/dev/null | wc -l)
    if [[ "$count" -gt 0 ]]; then
        log_info "Removing $count custom AirPrint service file(s) — CUPS handles dnssd natively"
        rm -f "$AVAHI_SERVICES_DIR"/AirPrint-*.service
    else
        log_info "No custom AirPrint service files to remove"
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
    remove_custom_airprint_services
    reload_avahi
    verify_services

    log_info "Avahi configuration complete"
}

# Run if called directly (not sourced)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
