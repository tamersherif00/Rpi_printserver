#!/bin/bash
# Script to enable all CUPS printers to accept jobs
# Run this if printers show "Accepting Jobs: No" in the web interface

set -e

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

# Check if running as root
if [[ $EUID -ne 0 ]]; then
    echo "This script must be run as root (use sudo)"
    exit 1
fi

log_info "Enabling all printers to accept jobs..."

# Get list of all printers and enable them
printer_count=0
while read -r printer; do
    if [[ -n "$printer" ]]; then
        log_info "Enabling printer: $printer"
        cupsenable "$printer" 2>/dev/null || true
        cupsaccept "$printer" 2>/dev/null || true
        lpadmin -p "$printer" -o printer-is-shared=true 2>/dev/null || true
        ((printer_count++))
    fi
done < <(lpstat -p 2>/dev/null | awk '{print $2}')

log_info "Checking printer status..."
lpstat -a 2>/dev/null

echo
log_info "Done! All printers have been enabled to accept jobs."
log_info "Refresh the web interface to see the updated status."
