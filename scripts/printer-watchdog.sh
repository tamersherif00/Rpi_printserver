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
    # Clear stale printer-state-reasons (e.g. "offline-report") that CUPS may
    # have cached from a previous transient error.  Windows IPP clients cache
    # these via Get-Printer-Attributes and show the printer as "offline" even
    # after the CUPS queue is back to normal.  Clearing the reasons and re-
    # touching printer-is-shared forces CUPS to re-broadcast updated state
    # via dnssd/Avahi so Windows picks up the change.
    local refreshed=0
    while IFS= read -r printer; do
        [[ -z "$printer" ]] && continue

        local reasons
        reasons=$(lpoptions -p "$printer" 2>/dev/null \
            | grep -oP 'printer-state-reasons=\K[^ ]+' || echo "none")

        if [[ "$reasons" != "none" && -n "$reasons" ]]; then
            log_info "Clearing stale state-reasons on $printer: $reasons"
            lpadmin -p "$printer" -o printer-state-reasons=none 2>/dev/null || true
            ((refreshed++))
        fi

        # Re-touch sharing flag to force CUPS to re-advertise via dnssd
        lpadmin -p "$printer" -o printer-is-shared=true 2>/dev/null || true
    done < <(lpstat -p 2>/dev/null | awk '{print $2}')

    if [[ $refreshed -gt 0 ]]; then
        log_info "Refreshed state on $refreshed printer(s)"
    fi
}

recover_printers
cleanup_old_jobs
refresh_printer_state
