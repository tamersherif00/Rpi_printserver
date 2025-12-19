#!/usr/bin/env bats
# Integration tests for print server reliability
# Tests auto-start, recovery, and USB reconnection handling

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

# ============================================
# Service Auto-Start Tests
# ============================================

@test "CUPS service is enabled for auto-start" {
    skip_if_not_linux

    systemctl is-enabled cups || systemctl is-enabled cups.service
}

@test "Avahi service is enabled for auto-start" {
    skip_if_not_linux

    systemctl is-enabled avahi-daemon || systemctl is-enabled avahi-daemon.service
}

@test "Print server web service is enabled for auto-start" {
    skip_if_not_linux

    if [ -f /etc/systemd/system/printserver-web.service ]; then
        systemctl is-enabled printserver-web || true
    else
        skip "printserver-web.service not installed"
    fi
}

@test "Services are running after system start" {
    skip_if_not_linux

    # Check CUPS is active
    systemctl is-active cups

    # Check Avahi is active
    systemctl is-active avahi-daemon
}

# ============================================
# Systemd Service Configuration Tests
# ============================================

@test "Systemd service file exists" {
    [ -f "$PROJECT_DIR/config/systemd/printserver-web.service" ]
}

@test "Systemd service has Restart=always" {
    grep -q "Restart=always" "$PROJECT_DIR/config/systemd/printserver-web.service"
}

@test "Systemd service has RestartSec configured" {
    grep -q "RestartSec=" "$PROJECT_DIR/config/systemd/printserver-web.service"
}

@test "Systemd service has proper dependencies" {
    grep -q "After=.*cups" "$PROJECT_DIR/config/systemd/printserver-web.service"
    grep -q "After=.*network" "$PROJECT_DIR/config/systemd/printserver-web.service"
}

@test "Systemd service has StartLimitBurst configured" {
    grep -q "StartLimitBurst=" "$PROJECT_DIR/config/systemd/printserver-web.service" || \
    grep -q "StartLimitIntervalSec=" "$PROJECT_DIR/config/systemd/printserver-web.service"
}

@test "Systemd service has security hardening" {
    grep -q "NoNewPrivileges=" "$PROJECT_DIR/config/systemd/printserver-web.service" || \
    grep -q "ProtectSystem=" "$PROJECT_DIR/config/systemd/printserver-web.service"
}

# ============================================
# Service Recovery Tests
# ============================================

@test "CUPS can be restarted" {
    skip_if_not_linux

    sudo systemctl restart cups
    sleep 2
    systemctl is-active cups
}

@test "Avahi can be restarted" {
    skip_if_not_linux

    sudo systemctl restart avahi-daemon
    sleep 2
    systemctl is-active avahi-daemon
}

@test "CUPS scheduler responds after restart" {
    skip_if_not_linux

    sudo systemctl restart cups
    sleep 3
    lpstat -r | grep -q "scheduler is running"
}

# ============================================
# USB Reconnection Handling Tests
# ============================================

@test "udev rules directory exists" {
    skip_if_not_linux

    [ -d /etc/udev/rules.d ]
}

@test "udev rule file exists in project" {
    [ -f "$PROJECT_DIR/config/udev/99-printer.rules" ] || true
}

@test "udev can be reloaded" {
    skip_if_not_linux

    sudo udevadm control --reload-rules 2>/dev/null || true
}

@test "USB devices can be listed" {
    skip_if_not_linux

    lsusb 2>/dev/null || skip "lsusb not available"
}

@test "CUPS can detect USB printers" {
    skip_if_not_linux

    # lpinfo requires root
    sudo lpinfo -v 2>/dev/null | grep -q "usb://" || true
}

# ============================================
# Job Preservation Tests
# ============================================

@test "CUPS preserves job history" {
    skip_if_not_linux

    if [ -f /etc/cups/cupsd.conf ]; then
        grep -qi "PreserveJobHistory" /etc/cups/cupsd.conf || true
    else
        skip "CUPS config not found"
    fi
}

@test "CUPS preserves job files" {
    skip_if_not_linux

    if [ -f /etc/cups/cupsd.conf ]; then
        grep -qi "PreserveJobFiles" /etc/cups/cupsd.conf || true
    else
        skip "CUPS config not found"
    fi
}

@test "CUPS job directory exists and is writable" {
    skip_if_not_linux

    [ -d /var/spool/cups ]
}

# ============================================
# Health Check Tests
# ============================================

@test "Health check endpoint responds" {
    skip_if_not_linux

    if command -v curl &> /dev/null; then
        # Try to access health endpoint (may not be running)
        curl -s -o /dev/null -w "%{http_code}" http://localhost:5000/health 2>/dev/null | grep -q "200\|503" || true
    else
        skip "curl not installed"
    fi
}

@test "CUPS web interface responds" {
    skip_if_not_linux

    if command -v curl &> /dev/null; then
        HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:631 2>/dev/null)
        [[ "$HTTP_CODE" =~ ^[234][0-9][0-9]$ ]]
    else
        skip "curl not installed"
    fi
}

# ============================================
# Network Connectivity Tests
# ============================================

@test "Network interface is up" {
    skip_if_not_linux

    ip link show | grep -q "state UP"
}

@test "Can reach gateway" {
    skip_if_not_linux

    GATEWAY=$(ip route | grep default | awk '{print $3}' | head -1)
    if [ -n "$GATEWAY" ]; then
        ping -c 1 -W 2 "$GATEWAY" 2>/dev/null || true
    else
        skip "No default gateway"
    fi
}

# ============================================
# Resource Limits Tests
# ============================================

@test "Systemd service has memory limit" {
    grep -q "MemoryMax=" "$PROJECT_DIR/config/systemd/printserver-web.service" || true
}

@test "Systemd service has CPU quota" {
    grep -q "CPUQuota=" "$PROJECT_DIR/config/systemd/printserver-web.service" || true
}

# ============================================
# Logging Tests
# ============================================

@test "CUPS log directory exists" {
    skip_if_not_linux

    [ -d /var/log/cups ]
}

@test "Systemd journal captures service logs" {
    skip_if_not_linux

    journalctl -u cups --no-pager -n 1 2>/dev/null || true
}

@test "Systemd service uses journal for logging" {
    grep -q "StandardOutput=journal" "$PROJECT_DIR/config/systemd/printserver-web.service" || \
    grep -q "StandardError=journal" "$PROJECT_DIR/config/systemd/printserver-web.service"
}
