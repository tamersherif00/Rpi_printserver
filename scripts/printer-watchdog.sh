#!/bin/bash
# Printer Watchdog - runs every 10s via systemd timer
#
# 1. recover_printers: re-enables stopped/disabled printers (runs FIRST so
#    Windows sees an enabled printer on its next IPP poll within ~10s)
# 2. recover_stuck_jobs: cancels jobs stuck in processing for >120s
# 3. cleanup_old_jobs: purges completed jobs older than 1 hour

WAKE_SCRIPT="/opt/printserver/scripts/wake-printer.sh"
STUCK_JOB_TIMEOUT=120

log_info() {
    logger -t printer-watchdog "$1"
}

# Extract numeric job ID from lpstat -o line (handles hyphenated printer names)
extract_job_id() {
    echo "$1" | awk '{print $1}' | grep -oP '\d+$'
}

# Extract printer name from lpstat -o line (everything before -JobID)
extract_printer_name() {
    local printer_and_id
    printer_and_id=$(echo "$1" | awk '{print $1}')
    local jid
    jid=$(echo "$printer_and_id" | grep -oP '\d+$')
    echo "$printer_and_id" | sed "s/-${jid}$//"
}

recover_printers() {
    local recovered=0

    # Re-enable printers in stopped/disabled state
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        local printer
        printer=$(echo "$line" | awk '{print $2}')
        [[ -z "$printer" ]] && continue

        # Only recover if USB device is physically present
        local printer_uri
        printer_uri=$(lpstat -v "$printer" 2>/dev/null | awk '{print $4}')
        if [[ "$printer_uri" == usb://* ]]; then
            if ! grep -r -l "07" /sys/bus/usb/devices/*/bInterfaceClass >/dev/null 2>&1; then
                log_info "Skipping $printer - USB device not connected"
                continue
            fi
        fi

        log_info "Recovering stopped printer: $printer"
        cupsenable "$printer" 2>/dev/null || true
        cupsaccept "$printer" 2>/dev/null || true
        # Clear stale error message so Windows doesn't cache "Offline"
        lpadmin -p "$printer" -o printer-state-message="" 2>/dev/null || true
        ((recovered++))
    done < <(lpstat -p 2>/dev/null | grep -iE "disabled|stopped")

    # Also fix printers that are idle but not accepting jobs
    while IFS= read -r printer; do
        [[ -z "$printer" ]] && continue
        local accept_line
        accept_line=$(lpstat -a "$printer" 2>/dev/null)
        if echo "$accept_line" | grep -qi "not accepting"; then
            log_info "Re-enabling job acceptance on: $printer"
            cupsaccept "$printer" 2>/dev/null || true
            ((recovered++))
        fi
    done < <(lpstat -p 2>/dev/null | awk '{print $2}')

    if [[ $recovered -gt 0 ]]; then
        log_info "Recovered $recovered printer(s)"
    fi
}

recover_stuck_jobs() {
    local now
    now=$(date +%s)
    local recovered=0

    while IFS= read -r line; do
        [[ -z "$line" ]] && continue

        local job_id
        job_id=$(extract_job_id "$line")
        [[ -z "$job_id" ]] && continue

        local printer_name
        printer_name=$(extract_printer_name "$line")

        # Check if job is actually processing (not just pending in queue)
        local is_processing=0
        local job_info
        job_info=$(lpstat -l -o 2>/dev/null | grep -A5 "^${printer_name}-${job_id} " || true)
        if echo "$job_info" | grep -qi "Status:.*processing\|printing"; then
            is_processing=1
        fi
        if [[ $is_processing -eq 0 ]]; then
            local printer_status
            printer_status=$(lpstat -p "$printer_name" 2>/dev/null || true)
            if echo "$printer_status" | grep -qi "printing\|processing"; then
                is_processing=1
            fi
        fi

        if [[ $is_processing -eq 0 ]]; then
            # Job is pending (queued or waiting for retry), not stuck
            rm -f "/tmp/stuck-job-${job_id}" 2>/dev/null
            continue
        fi

        # Track how long this job has been in processing state
        local marker="/tmp/stuck-job-${job_id}"
        if [[ -f "$marker" ]]; then
            local started
            started=$(cat "$marker" 2>/dev/null || echo "$now")
            local elapsed=$(( now - started ))
            if [[ $elapsed -gt $STUCK_JOB_TIMEOUT ]]; then
                log_info "Job $job_id stuck processing for ${elapsed}s - canceling"
                cancel "$job_id" 2>/dev/null || true
                rm -f "$marker"
                ((recovered++))
            fi
        else
            echo "$now" > "$marker"
        fi
    done < <(lpstat -o 2>/dev/null)

    # Clean up markers for jobs no longer in the active queue
    for marker in /tmp/stuck-job-*; do
        [[ -f "$marker" ]] || continue
        local mid
        mid=$(basename "$marker" | sed 's/stuck-job-//')
        if ! lpstat -o 2>/dev/null | grep -q "\-${mid} "; then
            rm -f "$marker"
        fi
    done

    if [[ $recovered -gt 0 ]]; then
        log_info "Canceled $recovered stuck job(s)"
    fi
}

cleanup_old_jobs() {
    local now
    now=$(date +%s)
    local purged=0
    local max_age=3600

    while IFS= read -r job_entry; do
        [[ -z "$job_entry" ]] && continue
        local job_id
        job_id=$(extract_job_id "$job_entry")
        [[ -z "$job_id" ]] && continue

        # Check spool file age if it exists
        local spool_file="/var/spool/cups/d${job_id}-001"
        if [[ -f "$spool_file" ]]; then
            local file_time
            file_time=$(stat -c %Y "$spool_file" 2>/dev/null || echo "$now")
            local age=$(( now - file_time ))
            if [[ $age -gt $max_age ]]; then
                cancel -x "$job_id" 2>/dev/null && ((purged++)) || true
            fi
        fi
        # If no spool file, CUPS already cleaned it up via PreserveJobFiles.
        # Don't purge the metadata - let CUPS manage its own history.
    done < <(lpstat -W completed -o 2>/dev/null)

    if [[ $purged -gt 0 ]]; then
        log_info "Purged $purged completed job(s) older than 1h"
    fi
}

# Order matters: recover printers FIRST so Windows sees an enabled printer
# on its next poll, then handle stuck jobs, then clean up.
recover_printers
recover_stuck_jobs
cleanup_old_jobs