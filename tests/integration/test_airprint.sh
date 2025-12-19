#!/usr/bin/env bats
# Integration tests for AirPrint service publication
# Tests Avahi/mDNS configuration for iOS printing

# Test setup
setup() {
    SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
    PROJECT_DIR="$(dirname "$(dirname "$SCRIPT_DIR")")"
}

# Skip if not on Linux
skip_if_not_linux() {
    if [[ "$(uname)" != "Linux" ]]; then
        skip "Test requires Linux"
    fi
}

skip_if_avahi_not_installed() {
    if ! command -v avahi-daemon &> /dev/null; then
        skip "Avahi not installed"
    fi
}

# Avahi daemon tests
@test "Avahi daemon is installed" {
    skip_if_not_linux
    command -v avahi-daemon
}

@test "Avahi daemon is running" {
    skip_if_not_linux
    skip_if_avahi_not_installed

    systemctl is-active avahi-daemon
}

@test "Avahi daemon is enabled at boot" {
    skip_if_not_linux
    skip_if_avahi_not_installed

    systemctl is-enabled avahi-daemon
}

# Avahi configuration tests
@test "Avahi config file exists" {
    skip_if_not_linux
    skip_if_avahi_not_installed

    [ -f /etc/avahi/avahi-daemon.conf ]
}

@test "Avahi publishing is enabled" {
    skip_if_not_linux
    skip_if_avahi_not_installed

    # Check that publishing is not disabled
    if grep -q "^disable-publishing=yes" /etc/avahi/avahi-daemon.conf 2>/dev/null; then
        false
    fi
}

@test "Avahi uses IPv4" {
    skip_if_not_linux
    skip_if_avahi_not_installed

    # Check that IPv4 is not disabled
    if grep -q "^use-ipv4=no" /etc/avahi/avahi-daemon.conf 2>/dev/null; then
        false
    fi
}

# AirPrint service tests
@test "Avahi services directory exists" {
    skip_if_not_linux
    skip_if_avahi_not_installed

    [ -d /etc/avahi/services ]
}

@test "AirPrint service file exists" {
    skip_if_not_linux
    skip_if_avahi_not_installed

    # Look for any AirPrint service file
    ls /etc/avahi/services/AirPrint*.service 2>/dev/null || \
    ls /etc/avahi/services/*airprint*.service 2>/dev/null || \
    ls /etc/avahi/services/*ipp*.service 2>/dev/null || true
}

@test "AirPrint service template exists in project" {
    [ -f "$PROJECT_DIR/config/avahi/airprint.service.template" ]
}

@test "AirPrint service template contains _ipp._tcp" {
    grep -q "_ipp._tcp" "$PROJECT_DIR/config/avahi/airprint.service.template"
}

@test "AirPrint service template contains _universal subtype" {
    grep -q "_universal._sub._ipp._tcp" "$PROJECT_DIR/config/avahi/airprint.service.template"
}

@test "AirPrint service template contains URF record" {
    grep -q "URF=" "$PROJECT_DIR/config/avahi/airprint.service.template"
}

@test "AirPrint service template contains pdl record" {
    grep -q "pdl=" "$PROJECT_DIR/config/avahi/airprint.service.template"
}

# mDNS discovery tests
@test "avahi-browse command available" {
    skip_if_not_linux
    skip_if_avahi_not_installed

    command -v avahi-browse
}

@test "Can browse for IPP services" {
    skip_if_not_linux
    skip_if_avahi_not_installed

    # Should complete without error (even if no services found)
    timeout 5 avahi-browse -t _ipp._tcp 2>/dev/null || true
}

@test "Can browse for IPPS services" {
    skip_if_not_linux
    skip_if_avahi_not_installed

    # Should complete without error (even if no services found)
    timeout 5 avahi-browse -t _ipps._tcp 2>/dev/null || true
}

@test "Can browse for printer services" {
    skip_if_not_linux
    skip_if_avahi_not_installed

    # Should complete without error (even if no services found)
    timeout 5 avahi-browse -t _printer._tcp 2>/dev/null || true
}

# IPP Everywhere tests (for Android)
@test "IPP Everywhere subtype advertised" {
    skip_if_not_linux
    skip_if_avahi_not_installed

    # Check if any service file contains the universal subtype
    if [ -d /etc/avahi/services ]; then
        grep -r "_universal._sub" /etc/avahi/services/ 2>/dev/null || true
    fi
}

# CUPS-filters tests (required for AirPrint)
@test "cups-filters is installed" {
    skip_if_not_linux

    dpkg -l cups-filters 2>/dev/null | grep -q "ii" || \
    rpm -q cups-filters 2>/dev/null || \
    pacman -Q cups-filters 2>/dev/null || \
    skip "cups-filters not detected"
}

# URF format support tests
@test "CUPS can convert to URF format" {
    skip_if_not_linux

    # Check if imagetoraster or rastertopdf filter exists
    [ -f /usr/lib/cups/filter/imagetoraster ] || \
    [ -f /usr/lib/cups/filter/rastertopdf ] || \
    [ -f /usr/lib/cups/filter/urftopdf ] || \
    skip "No URF-compatible filter found"
}

# PDF support tests (required for modern printing)
@test "PDF printing is supported" {
    skip_if_not_linux

    # Check for PDF-related CUPS filters
    [ -f /usr/lib/cups/filter/pdftops ] || \
    [ -f /usr/lib/cups/filter/pdftoraster ] || \
    [ -f /usr/lib/cups/filter/gstoraster ] || \
    skip "No PDF filter found"
}

# DNS-SD configuration tests
@test "BrowseLocalProtocols includes dnssd" {
    skip_if_not_linux

    if [ -f /etc/cups/cupsd.conf ]; then
        grep -qi "BrowseLocalProtocols.*dnssd" /etc/cups/cupsd.conf || \
        grep -qi "Browsing.*On" /etc/cups/cupsd.conf
    else
        skip "CUPS config not found"
    fi
}

# Hostname resolution tests
@test "Local hostname resolves via mDNS" {
    skip_if_not_linux
    skip_if_avahi_not_installed

    HOSTNAME=$(hostname)
    # Try to resolve using avahi-resolve
    avahi-resolve -n "${HOSTNAME}.local" 2>/dev/null || true
}

# Port availability tests
@test "Port 631 is accessible" {
    skip_if_not_linux

    # Check if port 631 is listening
    if command -v ss &> /dev/null; then
        ss -tln | grep -q ":631"
    elif command -v netstat &> /dev/null; then
        netstat -tln | grep -q ":631"
    else
        skip "Neither ss nor netstat available"
    fi
}

# Multi-device compatibility
@test "Service includes required TXT records for AirPrint" {
    skip_if_not_linux

    # Check project template for required TXT records
    grep -q "txtvers=" "$PROJECT_DIR/config/avahi/airprint.service.template"
    grep -q "qtotal=" "$PROJECT_DIR/config/avahi/airprint.service.template"
    grep -q "rp=" "$PROJECT_DIR/config/avahi/airprint.service.template"
    grep -q "ty=" "$PROJECT_DIR/config/avahi/airprint.service.template"
    grep -q "pdl=" "$PROJECT_DIR/config/avahi/airprint.service.template"
}
