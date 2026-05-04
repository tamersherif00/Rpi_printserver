#!/bin/bash
# set-network.sh — manage IPv4 network configuration with root privileges.
# Called by the printserver web UI via sudoers.
#
# Subcommands:
#   show
#       Print JSON: backend (NetworkManager|dhcpcd|unknown), interfaces[],
#       active connection, current IPv4 mode (dhcp|static), addresses,
#       gateway, DNS. Used by the UI to populate the form.
#
#   static <iface> <ip/prefix> <gateway> <dns_csv>
#       Configure static IPv4 on <iface>. Example:
#         static wlan0 192.168.0.66/24 192.168.0.1 8.8.8.8,1.1.1.1
#       The change is applied immediately. WARNING: if the new IP/gateway
#       is wrong, the operator loses network access — recovery requires
#       local console.
#
#   dhcp <iface>
#       Revert <iface> to DHCP.
#
# Backend support:
#   1. NetworkManager (nmcli) — Pi OS Bookworm/Trixie default.
#   2. dhcpcd — Pi OS Bullseye and earlier; appends/replaces a per-interface
#      static block in /etc/dhcpcd.conf.
#
# Errors are written to stderr with a non-zero exit code so the Python
# caller can surface them to the user.

set -e
LANG=C
LC_ALL=C

ACTION="${1:-}"

err() { echo "Error: $*" >&2; exit 1; }
info() { echo "$*"; }

have_nm() {
    command -v nmcli >/dev/null 2>&1 && systemctl is-active --quiet NetworkManager
}

have_dhcpcd() {
    command -v dhcpcd >/dev/null 2>&1 && [[ -f /etc/dhcpcd.conf ]]
}

backend() {
    if have_nm; then echo "NetworkManager"
    elif have_dhcpcd; then echo "dhcpcd"
    else echo "unknown"
    fi
}

# Validate IPv4 dotted-quad
valid_ip() {
    local ip="$1"
    [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    local IFS=.
    local a b c d
    read -r a b c d <<<"$ip"
    for n in "$a" "$b" "$c" "$d"; do
        (( n >= 0 && n <= 255 )) || return 1
    done
    return 0
}

valid_cidr() {
    local cidr="$1"
    [[ "$cidr" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/([0-9]|[12][0-9]|3[0-2])$ ]] || return 1
    valid_ip "${cidr%/*}"
}

# JSON-safe escape for the limited values we emit (IPs, names, simple strings)
jq_str() {
    local s="${1:-}"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    printf '"%s"' "$s"
}

# ─── show ──────────────────────────────────────────────────────────────────
do_show() {
    local be
    be=$(backend)

    # Pick the active connection (prefer wifi/wlan, fall back to first up iface)
    local iface=""
    if have_nm; then
        # Active wifi connection if any, otherwise first active non-loopback
        iface=$(nmcli -t -f DEVICE,TYPE,STATE connection show --active 2>/dev/null \
            | awk -F: '$3=="activated" && $2 ~ /wireless|ethernet/ {print $1; exit}')
    fi
    if [[ -z "$iface" ]]; then
        iface=$(ip -o -4 route show default 2>/dev/null | awk '{print $5; exit}')
    fi
    [[ -z "$iface" ]] && iface="wlan0"

    local addr_cidr="" gateway="" dns="" mode="dhcp" conn_name=""

    if have_nm && [[ -n "$iface" ]]; then
        # Find the active connection name on this iface
        conn_name=$(nmcli -t -f NAME,DEVICE connection show --active 2>/dev/null \
            | awk -F: -v i="$iface" '$2==i {print $1; exit}')

        if [[ -n "$conn_name" ]]; then
            local method
            method=$(nmcli -t -f ipv4.method connection show "$conn_name" 2>/dev/null | cut -d: -f2)
            if [[ "$method" == "manual" ]]; then mode="static"; fi

            addr_cidr=$(nmcli -t -f IP4.ADDRESS device show "$iface" 2>/dev/null \
                | head -1 | cut -d: -f2)
            gateway=$(nmcli -t -f IP4.GATEWAY device show "$iface" 2>/dev/null \
                | head -1 | cut -d: -f2)
            dns=$(nmcli -t -f IP4.DNS device show "$iface" 2>/dev/null \
                | cut -d: -f2 | paste -sd, -)
        fi
    else
        # No NM — read from `ip` directly
        addr_cidr=$(ip -o -4 addr show dev "$iface" 2>/dev/null \
            | awk '{print $4; exit}')
        gateway=$(ip -o -4 route show default dev "$iface" 2>/dev/null \
            | awk '{print $3; exit}')
        dns=$(grep -E "^nameserver " /etc/resolv.conf 2>/dev/null \
            | awk '{print $2}' | paste -sd, -)
        # dhcpcd: detect static block for this iface
        if have_dhcpcd && grep -qE "^[[:space:]]*interface[[:space:]]+$iface\b" /etc/dhcpcd.conf 2>/dev/null; then
            mode="static"
        fi
    fi

    # Emit JSON
    printf '{'
    printf '"backend":%s,'      "$(jq_str "$be")"
    printf '"interface":%s,'    "$(jq_str "$iface")"
    printf '"connection":%s,'   "$(jq_str "$conn_name")"
    printf '"mode":%s,'         "$(jq_str "$mode")"
    printf '"address":%s,'      "$(jq_str "$addr_cidr")"
    printf '"gateway":%s,'      "$(jq_str "$gateway")"
    printf '"dns":%s'           "$(jq_str "$dns")"
    printf '}\n'
}

# ─── static ────────────────────────────────────────────────────────────────
do_static() {
    local iface="${2:-}" cidr="${3:-}" gateway="${4:-}" dns_csv="${5:-}"

    [[ -n "$iface" ]]   || err "interface required"
    [[ -n "$cidr" ]]    || err "ip/prefix required (e.g. 192.168.0.66/24)"
    [[ -n "$gateway" ]] || err "gateway required"

    valid_cidr "$cidr"     || err "invalid ip/prefix '$cidr'"
    valid_ip   "$gateway"  || err "invalid gateway '$gateway'"

    # Validate each DNS entry (csv); empty allowed → fall back to gateway
    local dns_space=""
    if [[ -n "$dns_csv" ]]; then
        local IFS=,
        for d in $dns_csv; do
            d="${d// /}"
            [[ -z "$d" ]] && continue
            valid_ip "$d" || err "invalid DNS '$d'"
            dns_space+="$d "
        done
        unset IFS
        dns_space="${dns_space% }"
    fi

    if have_nm; then
        local conn_name
        conn_name=$(nmcli -t -f NAME,DEVICE connection show --active 2>/dev/null \
            | awk -F: -v i="$iface" '$2==i {print $1; exit}')
        [[ -n "$conn_name" ]] || err "no active NetworkManager connection on $iface"

        info "Applying static IP via NetworkManager on connection '$conn_name'..."
        nmcli con mod "$conn_name" \
            ipv4.method manual \
            ipv4.addresses "$cidr" \
            ipv4.gateway "$gateway" \
            ipv4.dns "${dns_space:-$gateway}" \
            ipv4.ignore-auto-dns yes
        # Re-activate the connection (briefly drops the link)
        nmcli con up "$conn_name" >/dev/null
        info "ok: $iface set to $cidr (gw $gateway, dns ${dns_space:-$gateway})"
    elif have_dhcpcd; then
        info "Applying static IP via dhcpcd on $iface..."
        # Strip any existing block for this iface so we can replace cleanly.
        # The block ends at the next "interface ..." line or EOF.
        python3 - "$iface" "$cidr" "$gateway" "$dns_space" <<'PYEOF'
import sys, re, pathlib
iface, cidr, gateway, dns_space = sys.argv[1:5]
p = pathlib.Path("/etc/dhcpcd.conf")
src = p.read_text() if p.exists() else ""
# Remove any existing block for this iface (interface <name> ... up to next blank line / interface)
pat = re.compile(
    rf"(^|\n)interface\s+{re.escape(iface)}\b.*?(?=(\ninterface\s|\Z))",
    re.S,
)
src = pat.sub(r"\1", src).rstrip() + "\n"
block = (
    f"\ninterface {iface}\n"
    f"static ip_address={cidr}\n"
    f"static routers={gateway}\n"
)
if dns_space:
    block += f"static domain_name_servers={dns_space}\n"
p.write_text(src + block)
PYEOF
        systemctl restart dhcpcd 2>/dev/null || true
        info "ok: $iface set to $cidr (gw $gateway, dns ${dns_space:-default})"
    else
        err "no supported network backend (NetworkManager / dhcpcd) found"
    fi
}

# ─── dhcp ──────────────────────────────────────────────────────────────────
do_dhcp() {
    local iface="${2:-}"
    [[ -n "$iface" ]] || err "interface required"

    if have_nm; then
        local conn_name
        conn_name=$(nmcli -t -f NAME,DEVICE connection show --active 2>/dev/null \
            | awk -F: -v i="$iface" '$2==i {print $1; exit}')
        [[ -n "$conn_name" ]] || err "no active NetworkManager connection on $iface"

        info "Reverting $iface to DHCP via NetworkManager..."
        nmcli con mod "$conn_name" \
            ipv4.method auto \
            ipv4.addresses "" \
            ipv4.gateway "" \
            ipv4.dns "" \
            ipv4.ignore-auto-dns no
        nmcli con up "$conn_name" >/dev/null
        info "ok: $iface reverted to DHCP"
    elif have_dhcpcd; then
        info "Reverting $iface to DHCP via dhcpcd..."
        python3 - "$iface" <<'PYEOF'
import sys, re, pathlib
iface = sys.argv[1]
p = pathlib.Path("/etc/dhcpcd.conf")
if p.exists():
    src = p.read_text()
    pat = re.compile(
        rf"(^|\n)interface\s+{re.escape(iface)}\b.*?(?=(\ninterface\s|\Z))",
        re.S,
    )
    src = pat.sub(r"\1", src).rstrip() + "\n"
    p.write_text(src)
PYEOF
        systemctl restart dhcpcd 2>/dev/null || true
        info "ok: $iface reverted to DHCP"
    else
        err "no supported network backend (NetworkManager / dhcpcd) found"
    fi
}

case "$ACTION" in
    show)   do_show ;;
    static) do_static "$@" ;;
    dhcp)   do_dhcp   "$@" ;;
    "")     err "missing subcommand (show | static | dhcp)" ;;
    *)      err "unknown subcommand: $ACTION" ;;
esac
