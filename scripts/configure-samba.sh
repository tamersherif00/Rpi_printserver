#!/bin/bash
# Samba Configuration Script
# Configures Samba to share CUPS printers to Windows clients.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

log_info() {
    echo "[INFO] $1"
    logger -t configure-samba "[INFO] $1" 2>/dev/null || true
}

log_warn() {
    echo "[WARN] $1"
    logger -t configure-samba "[WARN] $1" 2>/dev/null || true
}

log_error() {
    echo "[ERROR] $1"
    logger -t configure-samba "[ERROR] $1" 2>/dev/null || true
}

check_samba_installed() {
    if ! command -v smbd &> /dev/null; then
        log_error "Samba is not installed. Run install.sh first."
        exit 1
    fi
}

install_smb_conf() {
    log_info "Installing Samba configuration..."

    # Try deployed location first, then repo location
    local smb_conf_src=""
    for candidate in \
        "/opt/printserver/config/samba/smb.conf" \
        "$PROJECT_DIR/config/samba/smb.conf"; do
        if [[ -f "$candidate" ]]; then
            smb_conf_src="$candidate"
            break
        fi
    done

    if [[ -z "$smb_conf_src" ]]; then
        log_error "smb.conf source not found"
        exit 1
    fi

    # Back up any existing config
    if [[ -f /etc/samba/smb.conf ]]; then
        cp /etc/samba/smb.conf /etc/samba/smb.conf.bak
        log_info "Backed up existing smb.conf to smb.conf.bak"
    fi

    cp "$smb_conf_src" /etc/samba/smb.conf
    log_info "Installed smb.conf from $smb_conf_src"
}

create_spool_dir() {
    log_info "Creating Samba spool directory..."
    mkdir -p /var/spool/samba
    chmod 1777 /var/spool/samba
    log_info "Samba spool directory ready: /var/spool/samba (1777)"
}

create_drivers_dir() {
    log_info "Creating printer drivers directory..."
    mkdir -p /var/lib/samba/printers
    chmod 755 /var/lib/samba/printers
    log_info "Printer drivers directory ready: /var/lib/samba/printers"
}

create_print_user() {
    local PRINT_USER="printuser"
    local PRINT_PASS="printserver"

    # Windows 10/11 blocks unauthenticated guest access (error 1272) regardless
    # of Samba config. A dedicated Samba account lets Windows authenticate
    # normally without requiring the "Enable insecure guest logons" Group Policy.

    # Create a no-login system account if it doesn't already exist.
    if ! id "$PRINT_USER" &>/dev/null; then
        useradd -r -M -s /usr/sbin/nologin -c "Samba Print User" "$PRINT_USER"
        log_info "Created system user: $PRINT_USER"
    fi

    # Register the user in Samba's own credential store (separate from /etc/passwd).
    printf '%s\n%s\n' "$PRINT_PASS" "$PRINT_PASS" | smbpasswd -a -s "$PRINT_USER"
    smbpasswd -e "$PRINT_USER"   # ensure the account is enabled
    log_info "Samba user '$PRINT_USER' ready (password: $PRINT_PASS)"
    log_warn "Change the default password with: sudo smbpasswd $PRINT_USER"
}

validate_config() {
    log_info "Validating Samba configuration..."
    if command -v testparm &> /dev/null; then
        if testparm -s /etc/samba/smb.conf > /dev/null 2>&1; then
            log_info "Samba configuration is valid"
        else
            log_warn "testparm reported issues - check /etc/samba/smb.conf"
        fi
    fi
}

enable_and_restart_samba() {
    log_info "Enabling and starting Samba services..."

    systemctl enable smbd nmbd 2>/dev/null || true
    systemctl restart smbd nmbd

    sleep 2

    if systemctl is-active --quiet smbd; then
        log_info "smbd is running"
    else
        log_warn "smbd may not have started correctly"
    fi

    if systemctl is-active --quiet nmbd; then
        log_info "nmbd is running (NetBIOS name resolution)"
    else
        log_warn "nmbd may not have started - Windows may need manual IP entry"
    fi
}

verify_shares() {
    log_info "Verifying Samba printer shares..."
    if command -v smbclient &> /dev/null; then
        smbclient -L localhost -N 2>/dev/null | grep -i "print\|Printer" || \
            log_warn "No printer shares visible yet - CUPS may still be starting"
    fi
}

main() {
    log_info "Starting Samba configuration..."

    check_samba_installed
    install_smb_conf
    create_spool_dir
    create_drivers_dir
    create_print_user
    validate_config
    enable_and_restart_samba
    verify_shares

    log_info "Samba configuration complete"
    log_info "Windows clients should now see the printer at: \\\\$(hostname)\\printers"
    log_info "Or add it manually: http://$(hostname -I | awk '{print $1}'):631/printers/HL-L2340D-series"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    if [[ $EUID -ne 0 ]]; then
        echo "This script must be run as root (use sudo)"
        exit 1
    fi
    main "$@"
fi
