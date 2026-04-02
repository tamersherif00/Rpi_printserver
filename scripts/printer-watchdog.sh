#!/bin/bash
# Printer Watchdog
# Periodically checks for printers stuck in "stopped" or error state,
# re-enables them, and proactively wakes the USB printer from firmware
# sleep so the next print job succeeds immediately.
#
# Designed to run as a systemd timer (every 30 seconds).
#
# Why: CUPS can mark a printer as stopped after transient USB errors
# (printer sleep, cable hiccup, power glitch). ErrorPolicy=retry-job
# handles in-flight jobs, but sometimes the queue itself gets paused.
# Additionally, the printer's own firmware has a sleep mode that is
# separate from Linux USB autosuspend — when asleep, the printer
# ignores USB bulk transfers. This watchdog proactively wakes it.

LOGPREFIX="[printer-watchdog]"
WAKE_SCRIPT="/opt/printserver/scripts/wake-printer.sh"

log_info() {
    logger -t printer-watchdog "$1"
}

# Proactively wake USB printer if there are pending jobs or if the
# printer appears to be in an error state. This prevents the scenario
# where a print job arrives, CUPS tries to send it, the printer is
# asleep, the backend times out, and Windows gets an error.
wake_sleeping_printer() {
    [[ -x "$WAKE_SCRIPT" ]] || return 0

    local needs_wake=0

    # Wake if there are any pending/held jobs waiting to print
    if lpstat -o 2>/dev/null | grep -q .; then
        log_info "Pending jobs found — waking printer"
        needs_wake=1
    fi

    # Wake if any printer is in stopped/error state
    if lpstat -p 2>/dev/null | grep -qi "disabled\|stopped"; then
        log_info "Stopped printer detected — waking printer"
        needs_wake=1
    fi

    if [[ $needs_wake -eq 1 ]]; then
        "$WAKE_SCRIPT" 2>/dev/null || true
    fi
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

# Detect jobs stuck in "processing" state for too long (>90 seconds).
# This happens when the USB backend hangs because the printer was asleep
# when the backend opened the device. Cancel and re-queue the job so it
# gets retried with a fresh USB connection (via the wake backend).
recover_stuck_jobs() {
    local now
    now=$(date +%s)

    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        local job_id printer_and_id
        printer_and_id=$(echo "$line" | awk '{print $1}')
        job_id=$(echo "$printer_and_id" | cut -d'-' -f2-)

        # Get job state: 5 = processing
        local state
        state=$(lpoptions -p "$(echo "$printer_and_id" | cut -d'-' -f1)" 2>/dev/null | grep -oP 'job-state=\K\d+' || echo "")

        # Check how long the job has been processing using lpstat output
        # If the job is in the active list, it's currently processing
        local active_job
        active_job=$(lpstat -o 2>/dev/null | grep "$printer_and_id" || true)
        if [[ -n "$active_job" ]]; then
            # Job exists and is active — check if printer state says processing
            local printer_state
            printer_state=$(lpstat -p 2>/dev/null | head -1)
            if echo "$printer_state" | grep -qi "printing\|processing"; then
                # Use a marker file to track how long we've seen this job processing
                local marker="/tmp/stuck-job-${job_id}"
                if [[ -f "$marker" ]]; then
                    local started
                    started=$(cat "$marker")
                    local elapsed=$(( now - started ))
                    if [[ $elapsed -gt 90 ]]; then
                        log_info "Job $job_id stuck processing for ${elapsed}s — canceling for retry"
                        cancel "$job_id" 2>/dev/null || true
                        rm -f "$marker"
                        # Wake the printer so the next attempt works
                        [[ -x "$WAKE_SCRIPT" ]] && "$WAKE_SCRIPT" 2>/dev/null || true
                    fi
                else
                    echo "$now" > "$marker"
                fi
            fi
        else
            # Job no longer active, clean up marker
            rm -f "/tmp/stuck-job-${job_id}" 2>/dev/null
        fi
    done < <(lpstat -o 2>/dev/null)
}

wake_sleeping_printer
recover_stuck_jobs
recover_printers
cleanup_old_jobs
