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

    # cupsctl talks to CUPS over HTTP (localhost:631). Even after lpstat confirms
    # the scheduler is running, the socket can still refuse connections briefly.
    # Retry up to 5 times with a 3-second backoff before giving up (non-fatal).
    local max_attempts=5
    local attempt=1
    while [[ $attempt -le $max_attempts ]]; do
        if cupsctl --share-printers 2>/dev/null && cupsctl --remote-any 2>/dev/null; then
            log_info "Printer sharing enabled"
            return 0
        fi
        log_warn "cupsctl attempt $attempt/$max_attempts failed, retrying in 3s..."
        sleep 3
        ((attempt++))
    done

    log_warn "cupsctl could not enable sharing after $max_attempts attempts (non-fatal)."
    log_warn "Run manually once CUPS is stable:  cupsctl --share-printers --remote-any"
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

    # Poll until the CUPS scheduler is accepting connections (not just running).
    # `lpstat -r` tests the HTTP socket at localhost:631; `systemctl is-active`
    # only checks the process, which becomes active before the socket is ready.
    local max_attempts=20
    local attempt=1
    while [[ $attempt -le $max_attempts ]]; do
        if lpstat -r 2>/dev/null | grep -q "scheduler is running"; then
            log_info "CUPS scheduler is ready (attempt $attempt)"
            return 0
        fi
        log_info "Waiting for CUPS scheduler (attempt $attempt/$max_attempts)..."
        sleep 2
        ((attempt++))
    done
    log_warn "CUPS scheduler not confirmed ready after $max_attempts attempts — continuing"
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
