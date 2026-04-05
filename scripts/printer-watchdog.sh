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

cleanup_old_jobs() {
    # Purge completed jobs older than 1 hour to free memory and disk on 1GB Pi.
    # CUPS keeps job metadata in RAM; hundreds of stale jobs cause bloat.
    local purged=0
    while IFS= read -r job_entry; do
        job_id=$(echo "$job_entry" | awk '{print $1}' | cut -d'-' -f2)
        if [[ -n "$job_id" ]]; then
            cancel -x "$job_id" 2>/dev/null && ((purged++)) || true
        fi
    done < <(lpstat -W completed -o 2>/dev/null)
    if [[ $purged -gt 0 ]]; then
        log_info "Purged $purged completed job(s)"
    fi
}

refresh_printer_state() {
    # Fix printers that are actually broken — but ONLY when something is wrong.
    #
    # IMPORTANT: Do NOT call lpadmin on every cycle. Each lpadmin call triggers
    # a CUPS-Add-Modify-Printer event that causes CUPS to re-broadcast via
    # dnssd/Avahi. Windows sees the printer disappearing and reappearing every
    # 2 minutes, eventually marking it as unreliable and refusing to send jobs.
    # Only modify the printer when there's an actual error to clear.
    while IFS= read -r printer; do
        [[ -z "$printer" ]] && continue

        local needs_fix=0

        # Check if printer is stopped/disabled — this is an actual problem
        local state
        state=$(lpstat -p "$printer" 2>/dev/null || true)
        if echo "$state" | grep -qi "disabled\|stopped\|not ready"; then
            log_info "Recovering $printer (was stopped/disabled)"
            cupsenable "$printer" 2>/dev/null || true
            cupsaccept "$printer" 2>/dev/null || true
            needs_fix=1
        fi

        # Check if there are actual error reasons to clear
        local reasons
        reasons=$(lpoptions -p "$printer" 2>/dev/null \
            | grep -oP 'printer-state-reasons=\K[^ ]+' || echo "none")
        if [[ "$reasons" != "none" && -n "$reasons" ]]; then
            log_info "Clearing error reasons on $printer: $reasons"
            lpadmin -p "$printer" -o printer-state-reasons=none 2>/dev/null || true
            needs_fix=1
        fi

        if [[ $needs_fix -gt 0 ]]; then
            log_info "Printer $printer recovered"
        fi
    done < <(lpstat -p 2>/dev/null | awk '{print $2}')
}

recover_printers
cleanup_old_jobs
refresh_printer_state
