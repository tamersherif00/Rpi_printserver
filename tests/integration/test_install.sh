#!/usr/bin/env bats
# Integration tests for install.sh script
# Requires: bats-core (https://github.com/bats-core/bats-core)

# Test setup
setup() {
    SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
    PROJECT_DIR="$(dirname "$(dirname "$SCRIPT_DIR")")"
    INSTALL_SCRIPT="$PROJECT_DIR/scripts/install.sh"
}

# Verify script exists and is executable
@test "install.sh exists" {
    [ -f "$INSTALL_SCRIPT" ]
}

@test "install.sh has correct shebang" {
    head -1 "$INSTALL_SCRIPT" | grep -q "#!/bin/bash"
}

@test "install.sh contains required functions" {
    grep -q "check_root" "$INSTALL_SCRIPT"
    grep -q "install_system_packages" "$INSTALL_SCRIPT"
    grep -q "configure_cups" "$INSTALL_SCRIPT"
    grep -q "configure_avahi" "$INSTALL_SCRIPT"
}

@test "install.sh includes all required packages" {
    grep -q "cups" "$INSTALL_SCRIPT"
    grep -q "avahi-daemon" "$INSTALL_SCRIPT"
    grep -q "python3" "$INSTALL_SCRIPT"
}

# Test supporting scripts exist
@test "configure-cups.sh exists" {
    [ -f "$PROJECT_DIR/scripts/configure-cups.sh" ]
}

@test "configure-avahi.sh exists" {
    [ -f "$PROJECT_DIR/scripts/configure-avahi.sh" ]
}

@test "configure-wifi.sh exists" {
    [ -f "$PROJECT_DIR/scripts/configure-wifi.sh" ]
}

# Test config templates exist
@test "cupsd.conf.template exists" {
    [ -f "$PROJECT_DIR/config/cups/cupsd.conf.template" ]
}

@test "airprint.service.template exists" {
    [ -f "$PROJECT_DIR/config/avahi/airprint.service.template" ]
}

@test "systemd service file exists" {
    [ -f "$PROJECT_DIR/config/systemd/printserver-web.service" ]
}

# Test cupsd.conf.template contains required settings
@test "cupsd.conf.template enables network listening" {
    grep -q "Listen \*:631" "$PROJECT_DIR/config/cups/cupsd.conf.template"
}

@test "cupsd.conf.template enables browsing" {
    grep -q "Browsing On" "$PROJECT_DIR/config/cups/cupsd.conf.template"
}

@test "cupsd.conf.template sets BrowseLocalProtocols" {
    grep -q "BrowseLocalProtocols dnssd" "$PROJECT_DIR/config/cups/cupsd.conf.template"
}

@test "cupsd.conf.template allows LOCAL access" {
    grep -q "Allow @LOCAL" "$PROJECT_DIR/config/cups/cupsd.conf.template"
}

# Test AirPrint service template
@test "airprint.service.template contains IPP service" {
    grep -q "_ipp._tcp" "$PROJECT_DIR/config/avahi/airprint.service.template"
}

@test "airprint.service.template contains IPP Everywhere service" {
    grep -q "_ipps._tcp" "$PROJECT_DIR/config/avahi/airprint.service.template"
}

@test "airprint.service.template contains URF support" {
    grep -q "URF=" "$PROJECT_DIR/config/avahi/airprint.service.template"
}

# Test systemd service file
@test "systemd service depends on cups" {
    grep -q "cups.service" "$PROJECT_DIR/config/systemd/printserver-web.service"
}

@test "systemd service depends on avahi" {
    grep -q "avahi-daemon.service" "$PROJECT_DIR/config/systemd/printserver-web.service"
}

@test "systemd service has restart policy" {
    grep -q "Restart=always" "$PROJECT_DIR/config/systemd/printserver-web.service"
}

# Syntax validation tests
@test "install.sh passes shellcheck" {
    if command -v shellcheck &> /dev/null; then
        shellcheck "$INSTALL_SCRIPT"
    else
        skip "shellcheck not installed"
    fi
}

@test "configure-cups.sh passes shellcheck" {
    if command -v shellcheck &> /dev/null; then
        shellcheck "$PROJECT_DIR/scripts/configure-cups.sh"
    else
        skip "shellcheck not installed"
    fi
}

@test "configure-avahi.sh passes shellcheck" {
    if command -v shellcheck &> /dev/null; then
        shellcheck "$PROJECT_DIR/scripts/configure-avahi.sh"
    else
        skip "shellcheck not installed"
    fi
}

@test "configure-wifi.sh passes shellcheck" {
    if command -v shellcheck &> /dev/null; then
        shellcheck "$PROJECT_DIR/scripts/configure-wifi.sh"
    else
        skip "shellcheck not installed"
    fi
}
