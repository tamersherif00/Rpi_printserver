#!/bin/bash
# cups-pre-filter-wake.sh â€” DISABLED pass-through filter
#
# Previously this filter sent a USB reset to wake the printer before each job.
# This caused double/triple USB resets (combined with the backend wrapper and
# systemd path unit), confusing Brother printer firmware into blank-page loops.
#
# Wake responsibility now lives exclusively in usb-printer-wake-backend.
#
# This script is kept as a pure pass-through so that any old CUPS filter
# registrations (printserver-wake.convs) don't break the filter chain.
# It does NO wake operations â€” just passes data through unchanged.

# Pass-through: if a filename was given as $6, cat it; otherwise cat stdin.
# This is the standard CUPS filter pass-through pattern.
if [[ $# -ge 6 && -n "$6" ]]; then
    exec cat "$6"
else
    exec cat
fi
