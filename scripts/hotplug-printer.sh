#!/bin/bash
# hotplug-printer.sh — USB printer connect/disconnect handler
# Triggered by udev; handles CUPS auto-add and Avahi re-advertisement.
#
# Usage: hotplug-printer.sh [add|remove]
#
# On connect  (add):
#   1. Wait for CUPS scheduler to accept connections
#   2. Find the USB printer URI via lpinfo -v
#   3. Add a CUPS queue with driver "everywhere" (IPP Everywhere / driverless)
#   4. Enable the queue, start accepting jobs, mark as shared
#   5. Trigger configure-avahi.sh so Avahi advertises the printer via mDNS
#      → Windows 10/11, iOS, Android will auto-discover it
#
# On disconnect (remove):
#   The CUPS queue is kept so queued jobs survive a cable reconnect.
#   configure-avahi.sh is re-run to clean up stale Avahi entries.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ACTION="${1:-add}"

log() {
    logger -t printer-hotplug "$*"
    echo "[$(date '+%F %T')] $*"
}

wait_for_cups() {
    local attempts=0
    while [[ $attempts -lt 20 ]]; do
        lpstat -r 2>/dev/null | grep -q "scheduler is running" && return 0
        sleep 2
        ((attempts++))
    done
    log "CUPS not ready after 40 s — giving up"
    return 1
}

add_printer() {
    wait_for_cups || return 1

    # lpinfo -v lists all available device URIs.  We want the first USB one.
    local uri
    uri=$(lpinfo -v 2>/dev/null | awk '/^direct usb:/{print $2; exit}')

    if [[ -z "$uri" ]]; then
        local ip
        ip=$(hostname -I 2>/dev/null | awk '{print $1}')
        log "No USB printer visible to CUPS yet."
        log "If this is a first-time connection, add it manually:"
        log "  http://${ip}:631  → Administration → Add Printer"
        return 0
    fi

    # Build a CUPS-safe queue name from the URI
    # e.g. usb://Brother/HL-L2340D%20series → Brother_HL-L2340D_series
    local name
    name=$(echo "$uri" \
        | sed 's|usb://||' \
        | sed 's|%[0-9A-Fa-f]\{2\}| |g' \
        | tr -s '/ ?&=' '_' \
        | sed 's/^_//; s/_$//')

    if ! lpstat -p "$name" 2>/dev/null | grep -q "$name"; then
        log "Adding CUPS queue '$name' for $uri ..."

        # CRITICAL: DO NOT use -m everywhere (sends RGB data that monochrome
        # Brother lasers cannot render -> infinite blank pages).
        local model
        model=$(echo "$uri" | sed 's|usb://[^/]*/||' | sed 's|%20.*||' | sed 's|?.*||')

        local brlaser_ppd=""
        if [[ -n "$model" ]]; then
            brlaser_ppd=$(lpinfo -m 2>/dev/null | grep -i "brlaser" | grep -i "$model" | head -1 | awk '{print $1}')
        fi

        if [[ -n "$brlaser_ppd" ]] && lpadmin -p "$name" -E -v "$uri" -m "$brlaser_ppd" 2>/dev/null; then
            lpadmin -d "$name" 2>/dev/null || true
            log "Queue '$name' added (driver: $brlaser_ppd)"
        elif lpadmin -p "$name" -E -v "$uri" -m "drv:///cupsfilters.drv/pwgrast.ppd" 2>/dev/null; then
            lpadmin -d "$name" 2>/dev/null || true
            log "Queue '$name' added (PWG Raster / generic)"
        else
            log "lpadmin failed - add the printer via the CUPS web UI"
        fi
    else
        log "Queue '$name' already exists — skipping lpadmin"
    fi

    # Enable sharing for every configured queue (handles pre-existing queues too)
    while IFS= read -r printer; do
        [[ -z "$printer" ]] && continue
        cupsenable  "$printer" 2>/dev/null || true
        cupsaccept  "$printer" 2>/dev/null || true
        lpadmin -p  "$printer" -o printer-is-shared=true 2>/dev/null || true
        log "Printer '$printer': enabled, accepting jobs, shared"
    done < <(lpstat -p 2>/dev/null | awk '{print $2}')
}

remove_printer() {
    log "USB printer removed — CUPS queues preserved for reconnect"
}

case "$ACTION" in
    add)
        add_printer
        sleep 2
        "$SCRIPT_DIR/configure-avahi.sh" 2>/dev/null || true
        ;;
    remove)
        remove_printer
        sleep 5
        "$SCRIPT_DIR/configure-avahi.sh" 2>/dev/null || true
        ;;
    *)
        log "Unknown action: $ACTION (expected add or remove)"
        exit 1
        ;;
esac
