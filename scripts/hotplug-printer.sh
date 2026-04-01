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
        if lpadmin -p "$name" -E -v "$uri" -m everywhere 2>/dev/null; then
            lpadmin -d "$name" 2>/dev/null || true   # set as default
            log "Queue '$name' added (driverless/IPP Everywhere)"
        else
            # Driver-less setup failed — printer may need a specific PPD.
            # Leave setup to the user via the CUPS web UI; still continue to
            # enable + share any queue that already exists under a different name.
            log "lpadmin -m everywhere failed — add the printer via the CUPS web UI"
        fi
    else
        log "Queue '$name' already exists — skipping lpadmin"
    fi

    # Enable sharing for every real USB/IPP queue.
    # Skip ghost queues pointing to /dev/null (created by failed hotplug
    # attempts) — enabling them causes Windows to see phantom printers.
    while IFS= read -r printer; do
        [[ -z "$printer" ]] && continue
        local dev_uri
        dev_uri=$(lpstat -v "$printer" 2>/dev/null | awk '{print $NF}')
        if [[ "$dev_uri" == *"/dev/null"* ]]; then
            log "Removing ghost queue '$printer' (uri=$dev_uri)"
            lpadmin -x "$printer" 2>/dev/null || true
            continue
        fi
        cupsenable  "$printer" 2>/dev/null || true
        cupsaccept  "$printer" 2>/dev/null || true
        lpadmin -p  "$printer" -o printer-is-shared=true 2>/dev/null || true
        lpadmin -p  "$printer" -o printer-error-policy=retry-job 2>/dev/null || true
        log "Printer '$printer': enabled, accepting jobs, shared (uri=$dev_uri)"
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
