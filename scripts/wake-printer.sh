#!/bin/bash
# wake-printer.sh â€” Wake a USB printer from firmware sleep mode
#
# The kernel's USB autosuspend (disabled by our udev rules) only controls the
# Linux-side power state.  The printer's own firmware has a separate sleep/
# power-save mode that kicks in after idle time (typically 5-15 minutes).
# When asleep, the printer ignores USB bulk transfers until it receives a
# USB port reset or a specific wake sequence.
#
# This script:
#   1. Finds the USB printer's device node (/dev/bus/usb/BBB/DDD)
#   2. Sends a USBDEVFS_RESET ioctl to wake the printer firmware
#   3. Waits 4s for the print engine to fully initialize
#
# Usage:
#   wake-printer.sh              # wake all USB printers
#   wake-printer.sh <printer>    # wake specific CUPS queue
#
# Called by:
#   - usb-printer-wake-backend (before each print job)

set -euo pipefail

PRINTER_NAME="${1:-}"

log() {
    logger -t printer-wake "$*"
}

# Find USB printer device paths from sysfs
# Returns /dev/bus/usb/BBB/DDD paths for printer-class interfaces
find_usb_printer_devices() {
    local devices=()
    for intf in /sys/bus/usb/devices/*/bInterfaceClass; do
        [[ -f "$intf" ]] || continue
        local class
        class=$(cat "$intf" 2>/dev/null) || continue
        # Interface class 07 = Printer
        if [[ "$class" == "07" ]]; then
            local intf_dir
            intf_dir=$(dirname "$intf")
            # Go up to the USB device level (parent of the interface)
            local dev_dir
            dev_dir=$(dirname "$intf_dir")
            local busnum devnum
            busnum=$(cat "$dev_dir/busnum" 2>/dev/null) || continue
            devnum=$(cat "$dev_dir/devnum" 2>/dev/null) || continue
            local devpath
            devpath=$(printf "/dev/bus/usb/%03d/%03d" "$busnum" "$devnum")
            if [[ -e "$devpath" ]]; then
                devices+=("$devpath")
            fi
        fi
    done
    printf '%s\n' "${devices[@]}"
}

# Send USB reset to wake the printer from firmware sleep.
# Uses Python because there's no standard CLI for USBDEVFS_RESET ioctl.
usb_reset_device() {
    local devpath="$1"
    python3 -c "
import fcntl, os
USBDEVFS_RESET = 0x5514
try:
    fd = os.open('$devpath', os.O_WRONLY)
    fcntl.ioctl(fd, USBDEVFS_RESET, 0)
    os.close(fd)
except Exception as e:
    # Non-fatal: printer may already be awake or device node may be stale
    pass
" 2>/dev/null
}

wake_all() {
    local woke=0
    while IFS= read -r devpath; do
        [[ -z "$devpath" ]] && continue
        log "Sending USB reset to $devpath"
        usb_reset_device "$devpath"
        ((woke++))
    done < <(find_usb_printer_devices)

    if [[ $woke -eq 0 ]]; then
        log "No USB printer devices found to wake"
        return 1
    fi

    # Give the printer firmware time to re-initialize after reset.
    # Brother printers need 4-5s for the print engine (not just USB enumeration).
    # 2s caused blank pages because data arrived before the engine was ready.
    sleep 4

    # NOTE: We do NOT re-enable stopped CUPS queues here.  That is the
    # watchdog's job (runs every 10s).  Re-enabling here would mask real
    # errors: if the printer is stopped because of a hardware fault, we
    # don't want to blindly re-enable it on every wake attempt.

    log "Woke $woke USB printer device(s)"
    return 0
}

wake_specific() {
    local printer="$1"

    # Get the URI for this CUPS queue to find its USB device
    local uri
    uri=$(lpstat -v "$printer" 2>/dev/null | awk '{print $NF}' | tr -d ':')
    if [[ "$uri" != usb://* ]]; then
        log "$printer is not a USB printer (uri=$uri), skipping wake"
        return 0
    fi

    # Wake all USB printers (simpler and more reliable than matching URIs
    # to sysfs paths, and most setups have exactly one USB printer)
    wake_all
    # NOTE: We do NOT re-enable the CUPS queue here.  The watchdog (10s timer)
    # handles queue recovery.  Re-enabling here would mask real errors and
    # create races with the backend wrapper.
}

if [[ -n "$PRINTER_NAME" ]]; then
    wake_specific "$PRINTER_NAME"
else
    wake_all
fi
