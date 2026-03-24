#!/bin/bash
# Printer Watchdog
# Periodically checks for printers stuck in "stopped" or error state
# and re-enables them. Designed to run as a systemd timer.
#
# Why: CUPS can mark a printer as stopped after transient USB errors
# (printer sleep, cable hiccup, power glitch). ErrorPolicy=retry-job
# handles in-flight jobs, but sometimes the queue itself gets paused.
# This watchdog catches those cases.

LOGPREFIX="[printer-watchdog]"

log_info() {
    logger -t printer-watchdog "$1"
}

# Get all stopped/disabled printers
recover_printers() {
    local recovered=0

    # Check for printers in stopped state (state 5)
    while IFS= read -r line; do
        printer=$(echo "$line" | awk '{print $2}')
        if [[ -z "$printer" ]]; then
            continue
        fi

        # Check if the printer's USB device is actually present
        printer_uri=$(lpstat -v "$printer" 2>/dev/null | awk '{print $4}')
        if [[ "$printer_uri" == usb://* ]]; then
            # Only recover if a USB printer device exists
            if ! lpinfo -v 2>/dev/null | grep -q "usb://"; then
                log_info "Skipping $printer — USB device not connected"
                continue
            fi
        fi

        log_info "Recovering stopped printer: $printer"
        cupsenable "$printer" 2>/dev/null || true
        cupsaccept "$printer" 2>/dev/null || true
        ((recovered++))
    done < <(lpstat -p 2>/dev/null | grep -i "disabled\|stopped")

    # Also check for printers not accepting jobs
    while IFS= read -r printer; do
        if [[ -n "$printer" ]]; then
            state=$(lpoptions -p "$printer" 2>/dev/null | grep -oP 'printer-state=\K\d+' || echo "")
            accepting=$(lpoptions -p "$printer" 2>/dev/null | grep -oP 'printer-is-accepting-jobs=\K\w+' || echo "")

            if [[ "$accepting" == "false" ]]; then
                log_info "Re-enabling job acceptance on: $printer"
                cupsaccept "$printer" 2>/dev/null || true
                ((recovered++))
            fi
        fi
    done < <(lpstat -p 2>/dev/null | awk '{print $2}')

    if [[ $recovered -gt 0 ]]; then
        log_info "Recovered $recovered printer(s)"
    fi
}

recover_printers
