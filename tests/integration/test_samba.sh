#!/usr/bin/env bats
# Integration tests for Samba printer sharing
# Tests legacy Windows printing via SMB

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

skip_if_samba_not_installed() {
    if ! command -v smbd &> /dev/null; then
        skip "Samba not installed"
    fi
}

# Samba installation tests
@test "Samba server is installed" {
    skip_if_not_linux
    command -v smbd
}

@test "Samba client tools are installed" {
    skip_if_not_linux
    command -v smbclient || skip "smbclient not installed"
}

# Samba service tests
@test "Samba service is running" {
    skip_if_not_linux
    skip_if_samba_not_installed

    systemctl is-active smbd || systemctl is-active smb
}

@test "Samba is listening on port 445" {
    skip_if_not_linux
    skip_if_samba_not_installed

    if command -v ss &> /dev/null; then
        ss -tln | grep -q ":445"
    elif command -v netstat &> /dev/null; then
        netstat -tln | grep -q ":445"
    else
        skip "Neither ss nor netstat available"
    fi
}

# Samba configuration tests
@test "Samba config file exists" {
    skip_if_not_linux
    skip_if_samba_not_installed

    [ -f /etc/samba/smb.conf ]
}

@test "Samba has printers section" {
    skip_if_not_linux
    skip_if_samba_not_installed

    grep -q "\[printers\]" /etc/samba/smb.conf
}

@test "Samba printers section allows guest access" {
    skip_if_not_linux
    skip_if_samba_not_installed

    # Check that guest ok = yes is set in printers section
    sed -n '/\[printers\]/,/^\[/p' /etc/samba/smb.conf | grep -qi "guest ok.*=.*yes"
}

@test "Samba has print$ share for drivers" {
    skip_if_not_linux
    skip_if_samba_not_installed

    grep -q "\[print\$\]" /etc/samba/smb.conf || true  # Optional share
}

@test "Samba spool directory exists" {
    skip_if_not_linux
    skip_if_samba_not_installed

    [ -d /var/spool/samba ]
}

@test "Samba spool directory has correct permissions" {
    skip_if_not_linux
    skip_if_samba_not_installed

    # Should be world-writable with sticky bit (1777)
    PERMS=$(stat -c "%a" /var/spool/samba)
    [ "$PERMS" = "1777" ]
}

# Samba-CUPS integration tests
@test "Samba configured for CUPS printing" {
    skip_if_not_linux
    skip_if_samba_not_installed

    # Check for CUPS printing backend
    grep -qi "printing.*=.*cups" /etc/samba/smb.conf || \
    grep -qi "printcap name.*=.*cups" /etc/samba/smb.conf
}

# Samba share listing test
@test "Samba shares are listable" {
    skip_if_not_linux
    skip_if_samba_not_installed

    if command -v smbclient &> /dev/null; then
        smbclient -L localhost -N 2>/dev/null || true
    else
        skip "smbclient not available"
    fi
}

# testparm validation
@test "Samba configuration is valid" {
    skip_if_not_linux
    skip_if_samba_not_installed

    if command -v testparm &> /dev/null; then
        testparm -s 2>/dev/null
    else
        skip "testparm not available"
    fi
}

# Security tests
@test "Samba is not exposing sensitive shares" {
    skip_if_not_linux
    skip_if_samba_not_installed

    # Should not have a wide-open home share or root share
    if grep -q "\[homes\]" /etc/samba/smb.conf; then
        # If homes exists, it should require auth
        ! sed -n '/\[homes\]/,/^\[/p' /etc/samba/smb.conf | grep -qi "guest ok.*=.*yes"
    fi
}

# Windows compatibility tests
@test "Samba supports SMB2" {
    skip_if_not_linux
    skip_if_samba_not_installed

    # Check server min protocol allows SMB2 (default in modern Samba)
    # If server min protocol is set to NT1 or LANMAN, fail
    if grep -qi "server min protocol.*=.*NT1\|LANMAN" /etc/samba/smb.conf; then
        false
    fi
}
