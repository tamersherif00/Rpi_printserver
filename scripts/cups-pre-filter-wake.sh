#!/bin/bash
# cups-pre-filter-wake.sh — CUPS filter that wakes the printer before printing
#
# Installed as a CUPS filter with order 0 (runs before all other filters).
# CUPS calls filters with: filter job user title copies options [filename]
#
# This filter:
#   1. Sends a USB reset to wake the printer from firmware sleep
#   2. Waits briefly for the printer to initialize
#   3. Passes data through unchanged (cat) to the next filter in the chain
#
# Why a filter and not a backend wrapper:
#   Filters run BEFORE the backend tries to open the USB device, giving the
#   printer time to wake up. A backend wrapper would be too late — the USB
#   open() would already fail or timeout before we could intervene.

WAKE_SCRIPT="/opt/printserver/scripts/wake-printer.sh"

# Log to CUPS (stderr goes to error_log)
log() {
    echo "INFO: [wake-filter] $*" >&2
}

# Extract printer name from environment (CUPS sets PRINTER)
PRINTER="${PRINTER:-}"

if [[ -x "$WAKE_SCRIPT" ]]; then
    log "Waking printer '$PRINTER' before job $1"
    "$WAKE_SCRIPT" "$PRINTER" 2>/dev/null || true
fi

# Pass-through: if a filename was given as $6, cat it; otherwise cat stdin.
# This is the standard CUPS filter pass-through pattern.
if [[ $# -ge 6 && -n "$6" ]]; then
    exec cat "$6"
else
    exec cat
fi
