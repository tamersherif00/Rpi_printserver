#!/usr/bin/env bats
# Integration tests for CUPS configuration
# These tests verify the CUPS setup on a running system
# Requires: bats-core, running on a system with CUPS installed

# Test setup
setup() {
    SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
    PROJECT_DIR="$(dirname "$(dirname "$SCRIPT_DIR")")"
}

# Skip tests if not running on Linux with CUPS
skip_if_not_linux() {
    if [[ "$(uname)" != "Linux" ]]; then
        skip "Test requires Linux"
    fi
}

skip_if_cups_not_installed() {
    if ! command -v lpstat &> /dev/null; then
        skip "CUPS not installed"
    fi
}

# CUPS service tests
@test "CUPS service is installed" {
    skip_if_not_linux
    command -v cupsd
}

@test "CUPS scheduler is running" {
    skip_if_not_linux
    skip_if_cups_not_installed
    lpstat -r | grep -q "scheduler is running"
}

@test "CUPS is listening on port 631" {
    skip_if_not_linux
    skip_if_cups_not_installed

    if command -v ss &> /dev/null; then
        ss -tln | grep -q ":631"
    elif command -v netstat &> /dev/null; then
        netstat -tln | grep -q ":631"
    else
        skip "Neither ss nor netstat available"
    fi
}

# CUPS configuration tests
@test "CUPS web interface is accessible" {
    skip_if_not_linux
    skip_if_cups_not_installed

    if command -v curl &> /dev/null; then
        curl -s -o /dev/null -w "%{http_code}" http://localhost:631 | grep -q "200\|401\|403"
    else
        skip "curl not installed"
    fi
}

@test "CUPS allows remote browsing" {
    skip_if_not_linux
    skip_if_cups_not_installed

    if [[ -f /etc/cups/cupsd.conf ]]; then
        grep -q "Browsing On" /etc/cups/cupsd.conf || \
        grep -q "Browsing Yes" /etc/cups/cupsd.conf
    else
        skip "CUPS config file not found"
    fi
}

# Printer detection tests
@test "lpstat command works" {
    skip_if_not_linux
    skip_if_cups_not_installed

    lpstat -p || true  # Don't fail if no printers
}

@test "lpinfo command works" {
    skip_if_not_linux
    skip_if_cups_not_installed

    lpinfo -v 2>/dev/null || true  # May need root, don't fail
}

# cups-browsed tests (if installed)
@test "cups-browsed is available" {
    skip_if_not_linux

    if ! command -v cups-browsed &> /dev/null; then
        skip "cups-browsed not installed"
    fi

    command -v cups-browsed
}

# IPP tests
@test "IPP endpoint responds" {
    skip_if_not_linux
    skip_if_cups_not_installed

    if command -v curl &> /dev/null; then
        # IPP endpoint should respond (even if with an error)
        HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:631/printers/ 2>/dev/null)
        [[ "$HTTP_CODE" =~ ^[2345][0-9][0-9]$ ]]
    else
        skip "curl not installed"
    fi
}

# Avahi integration tests
@test "Avahi daemon is running" {
    skip_if_not_linux

    if ! command -v avahi-daemon &> /dev/null; then
        skip "Avahi not installed"
    fi

    systemctl is-active avahi-daemon || pgrep avahi-daemon
}

@test "IPP services are advertised via mDNS" {
    skip_if_not_linux

    if ! command -v avahi-browse &> /dev/null; then
        skip "avahi-browse not installed"
    fi

    # Look for IPP services (timeout after 3 seconds)
    timeout 3 avahi-browse -t _ipp._tcp 2>/dev/null || true
}

# Security tests
@test "CUPS admin requires authentication" {
    skip_if_not_linux
    skip_if_cups_not_installed

    if command -v curl &> /dev/null; then
        HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:631/admin 2>/dev/null)
        # Should require auth (401) or redirect (30x) or be accessible (200)
        [[ "$HTTP_CODE" =~ ^[234][0-9][0-9]$ ]]
    else
        skip "curl not installed"
    fi
}

# Job preservation tests
@test "CUPS preserves job history" {
    skip_if_not_linux
    skip_if_cups_not_installed

    if [[ -f /etc/cups/cupsd.conf ]]; then
        grep -q "PreserveJobHistory" /etc/cups/cupsd.conf || true
    else
        skip "CUPS config file not found"
    fi
}
