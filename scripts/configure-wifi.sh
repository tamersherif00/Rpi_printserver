#!/bin/bash
# WiFi Configuration Helper Script
# Helps configure WiFi on Raspberry Pi

set -e

log_info() {
    echo "[INFO] $1"
}

log_warn() {
    echo "[WARN] $1"
}

log_error() {
    echo "[ERROR] $1"
}

check_wifi_interface() {
    if ! ip link show wlan0 &> /dev/null; then
        log_error "No WiFi interface (wlan0) found"
        log_info "Ensure your Raspberry Pi has WiFi capability or a USB WiFi adapter"
        return 1
    fi
    log_info "WiFi interface found: wlan0"
    return 0
}

get_wifi_status() {
    log_info "Current WiFi status:"

    # Check if connected
    if iwgetid wlan0 -r &> /dev/null; then
        local ssid
        ssid=$(iwgetid wlan0 -r)
        log_info "Connected to: $ssid"

        # Get IP address
        local ip
        ip=$(ip -4 addr show wlan0 | grep -oP '(?<=inet\s)\d+(\.\d+){3}' || echo "No IP")
        log_info "IP Address: $ip"

        # Get signal strength
        local signal
        signal=$(iwconfig wlan0 2>/dev/null | grep -oP '(?<=Signal level=)-?\d+' || echo "Unknown")
        log_info "Signal strength: ${signal} dBm"
    else
        log_warn "Not connected to any WiFi network"
    fi
}

list_available_networks() {
    log_info "Scanning for available WiFi networks..."

    # Trigger a scan
    iwlist wlan0 scan 2>/dev/null | grep -oP '(?<=ESSID:")[^"]+' | sort -u || {
        log_warn "Could not scan for networks. Try running as root."
    }
}

configure_network() {
    local ssid="$1"
    local password="$2"

    if [[ -z "$ssid" ]]; then
        log_error "SSID is required"
        return 1
    fi

    log_info "Configuring WiFi network: $ssid"

    # Check for NetworkManager or wpa_supplicant
    if systemctl is-active NetworkManager &> /dev/null; then
        configure_with_networkmanager "$ssid" "$password"
    elif [[ -f /etc/wpa_supplicant/wpa_supplicant.conf ]]; then
        configure_with_wpa_supplicant "$ssid" "$password"
    else
        log_error "No supported WiFi configuration method found"
        return 1
    fi
}

configure_with_networkmanager() {
    local ssid="$1"
    local password="$2"

    log_info "Using NetworkManager to configure WiFi..."

    if [[ -n "$password" ]]; then
        nmcli device wifi connect "$ssid" password "$password"
    else
        nmcli device wifi connect "$ssid"
    fi

    log_info "WiFi configured via NetworkManager"
}

configure_with_wpa_supplicant() {
    local ssid="$1"
    local password="$2"

    log_info "Using wpa_supplicant to configure WiFi..."

    WPA_CONF="/etc/wpa_supplicant/wpa_supplicant.conf"

    # Backup existing config
    if [[ -f "$WPA_CONF" ]]; then
        cp "$WPA_CONF" "${WPA_CONF}.backup"
    fi

    # Check if network already exists
    if grep -q "ssid=\"$ssid\"" "$WPA_CONF" 2>/dev/null; then
        log_info "Network '$ssid' already configured"
        return 0
    fi

    # Add network configuration
    if [[ -n "$password" ]]; then
        # WPA/WPA2 network
        wpa_passphrase "$ssid" "$password" >> "$WPA_CONF"
    else
        # Open network
        cat >> "$WPA_CONF" << EOF

network={
    ssid="$ssid"
    key_mgmt=NONE
}
EOF
    fi

    log_info "WiFi network added to wpa_supplicant configuration"

    # Restart wpa_supplicant
    wpa_cli -i wlan0 reconfigure

    log_info "WiFi reconfigured"
}

set_static_ip() {
    local ip="$1"
    local gateway="$2"
    local dns="${3:-8.8.8.8}"

    if [[ -z "$ip" ]] || [[ -z "$gateway" ]]; then
        log_error "IP address and gateway are required"
        log_info "Usage: $0 static-ip <IP_ADDRESS> <GATEWAY> [DNS]"
        return 1
    fi

    log_info "Setting static IP: $ip"

    DHCPCD_CONF="/etc/dhcpcd.conf"

    # Backup existing config
    if [[ -f "$DHCPCD_CONF" ]]; then
        cp "$DHCPCD_CONF" "${DHCPCD_CONF}.backup"
    fi

    # Remove existing static IP config for wlan0
    sed -i '/^interface wlan0/,/^interface\|^$/d' "$DHCPCD_CONF" 2>/dev/null || true

    # Add static IP configuration
    cat >> "$DHCPCD_CONF" << EOF

interface wlan0
static ip_address=$ip/24
static routers=$gateway
static domain_name_servers=$dns
EOF

    log_info "Static IP configured. Restart dhcpcd or reboot to apply."
    log_info "Run: sudo systemctl restart dhcpcd"
}

enable_ap_mode() {
    log_info "Enabling Access Point mode for initial setup..."

    # This creates a temporary AP for initial configuration
    # Requires hostapd and dnsmasq

    if ! command -v hostapd &> /dev/null; then
        log_error "hostapd not installed. Run: sudo apt install hostapd dnsmasq"
        return 1
    fi

    log_info "AP mode setup requires additional configuration."
    log_info "See documentation for setting up a configuration AP."
}

print_usage() {
    echo "Usage: $0 <command> [options]"
    echo ""
    echo "Commands:"
    echo "  status              Show current WiFi status"
    echo "  scan                List available WiFi networks"
    echo "  connect <SSID> [PASSWORD]  Connect to a WiFi network"
    echo "  static-ip <IP> <GATEWAY> [DNS]  Set static IP address"
    echo "  help                Show this help message"
    echo ""
    echo "Examples:"
    echo "  $0 status"
    echo "  $0 scan"
    echo "  $0 connect MyNetwork MyPassword123"
    echo "  $0 static-ip 192.168.1.100 192.168.1.1"
}

main() {
    local command="${1:-status}"
    shift || true

    case "$command" in
        status)
            check_wifi_interface && get_wifi_status
            ;;
        scan)
            check_wifi_interface && list_available_networks
            ;;
        connect)
            check_wifi_interface && configure_network "$@"
            ;;
        static-ip)
            set_static_ip "$@"
            ;;
        ap|access-point)
            enable_ap_mode
            ;;
        help|--help|-h)
            print_usage
            ;;
        *)
            log_error "Unknown command: $command"
            print_usage
            exit 1
            ;;
    esac
}

main "$@"
