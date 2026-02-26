#!/bin/bash
# CUPS Configuration Script
# Configures CUPS for network printing, AirPrint, and Windows support

set -e

CUPS_CONFIG="/etc/cups/cupsd.conf"
CUPS_CONFIG_BACKUP="/etc/cups/cupsd.conf.backup"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

log_info() {
    echo "[INFO] $1"
}

log_warn() {
    echo "[WARN] $1"
}

backup_config() {
    if [[ -f "$CUPS_CONFIG" ]] && [[ ! -f "$CUPS_CONFIG_BACKUP" ]]; then
        log_info "Backing up original CUPS configuration..."
        cp "$CUPS_CONFIG" "$CUPS_CONFIG_BACKUP"
    fi
}

configure_cups() {
    log_info "Configuring CUPS for network access..."

    # Apply configuration from template if exists
    if [[ -f "$PROJECT_DIR/config/cups/cupsd.conf.template" ]]; then
        cp "$PROJECT_DIR/config/cups/cupsd.conf.template" "$CUPS_CONFIG"
        log_info "Applied CUPS configuration template"
    else
        # Manual configuration
        log_info "Applying manual CUPS configuration..."

        # Enable listening on all interfaces
        if ! grep -q "^Listen \*:631" "$CUPS_CONFIG"; then
            sed -i 's/^Listen localhost:631/Listen *:631/' "$CUPS_CONFIG"
        fi

        # Enable browsing
        if ! grep -q "^Browsing On" "$CUPS_CONFIG"; then
            sed -i 's/^Browsing Off/Browsing On/' "$CUPS_CONFIG"
        fi

        # Set BrowseLocalProtocols for service discovery
        if ! grep -q "^BrowseLocalProtocols" "$CUPS_CONFIG"; then
            echo "BrowseLocalProtocols dnssd" >> "$CUPS_CONFIG"
        fi

        # Allow remote access to web interface
        if ! grep -q "Allow @LOCAL" "$CUPS_CONFIG"; then
            # Add Allow @LOCAL to location blocks
            sed -i '/<Location \/>/,/<\/Location>/ s/Order allow,deny/Order allow,deny\n  Allow @LOCAL/' "$CUPS_CONFIG"
        fi
    fi
}

configure_sharing() {
    log_info "Enabling printer sharing..."

    # Enable sharing in CUPS
    cupsctl --share-printers
    cupsctl --remote-any

    # Allow remote administration (optional, for debugging)
    # cupsctl --remote-admin

    log_info "Printer sharing enabled"
}

configure_ipp() {
    log_info "Configuring IPP for Windows and mobile printing..."

    # Ensure IPP is enabled (default in modern CUPS)
    # IPP Everywhere support is built into cups-filters

    # Enable cups-browsed for better discovery
    if systemctl is-enabled cups-browsed > /dev/null 2>&1; then
        log_info "cups-browsed is enabled"
    else
        systemctl enable cups-browsed 2>/dev/null || true
    fi
}

configure_samba() {
    log_info "Configuring Samba for legacy Windows support..."

    SAMBA_CONFIG="/etc/samba/smb.conf"

    if [[ ! -f "$SAMBA_CONFIG" ]]; then
        log_warn "Samba config not found at $SAMBA_CONFIG, skipping"
        return 0
    fi

    # Check if CUPS printing section exists
    if ! grep -q "\[printers\]" "$SAMBA_CONFIG" 2>/dev/null; then
        log_info "Adding printer sharing to Samba configuration..."

        cat >> "$SAMBA_CONFIG" << 'EOF'

# Print server configuration
[printers]
   comment = All Printers
   browseable = yes
   path = /var/spool/samba
   printable = yes
   guest ok = yes
   read only = yes
   create mask = 0700

[print$]
   comment = Printer Drivers
   path = /var/lib/samba/printers
   browseable = yes
   read only = yes
   guest ok = yes
EOF
        log_info "Samba printer sharing configured"
    else
        log_info "Samba printer sharing already configured"
    fi

    # Create spool directory
    mkdir -p /var/spool/samba
    chmod 1777 /var/spool/samba
}

configure_job_preservation() {
    log_info "Configuring job preservation across restarts..."

    # Set job retention settings (conservative for 1GB Pi)
    if [[ -f "$CUPS_CONFIG" ]]; then
        # Preserve jobs for 12 hours after completion
        if ! grep -q "^PreserveJobHistory" "$CUPS_CONFIG"; then
            echo "PreserveJobHistory Yes" >> "$CUPS_CONFIG"
        fi
        if grep -q "^PreserveJobFiles" "$CUPS_CONFIG"; then
            sed -i 's/^PreserveJobFiles.*/PreserveJobFiles 12h/' "$CUPS_CONFIG"
        else
            echo "PreserveJobFiles 12h" >> "$CUPS_CONFIG"
        fi
        if grep -q "^MaxJobs" "$CUPS_CONFIG"; then
            sed -i 's/^MaxJobs.*/MaxJobs 100/' "$CUPS_CONFIG"
        else
            echo "MaxJobs 100" >> "$CUPS_CONFIG"
        fi
    fi
}

restart_cups() {
    log_info "Restarting CUPS service..."
    systemctl restart cups

    # Wait for CUPS to be ready
    sleep 2

    if systemctl is-active cups > /dev/null 2>&1; then
        log_info "CUPS is running"
    else
        log_warn "CUPS may not have started correctly"
        systemctl status cups
    fi
}

add_user_to_lpadmin() {
    log_info "Adding users to lpadmin group..."

    # Add pi user if exists
    if id "pi" > /dev/null 2>&1; then
        usermod -aG lpadmin pi
        log_info "Added 'pi' user to lpadmin group"
    fi

    # Add current user
    if [[ -n "$SUDO_USER" ]]; then
        usermod -aG lpadmin "$SUDO_USER"
        log_info "Added '$SUDO_USER' to lpadmin group"
    fi
}

main() {
    log_info "Starting CUPS configuration..."

    backup_config
    configure_cups
    configure_job_preservation

    # Restart CUPS now so the new config is loaded before cupsctl calls
    restart_cups

    configure_sharing
    configure_ipp
    configure_samba
    add_user_to_lpadmin

    log_info "CUPS configuration complete"
}

main "$@"
