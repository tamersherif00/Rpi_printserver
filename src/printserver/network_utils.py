"""Network configuration utilities for the print server.

Wraps `scripts/set-network.sh` to read and apply IPv4 settings from the
web UI. The bash helper is the single source of truth for which backend
(NetworkManager vs dhcpcd) is used.
"""

from __future__ import annotations

import json
import logging
import re
import subprocess
from typing import Optional

logger = logging.getLogger(__name__)

HELPER_SCRIPT = "/opt/printserver/scripts/set-network.sh"

# Strict IPv4 dotted-quad. We do NOT accept hostnames here because the
# helper script only validates IPv4 too.
_IP_RE = re.compile(
    r"^(?:(?:25[0-5]|2[0-4]\d|[01]?\d?\d)\.){3}(?:25[0-5]|2[0-4]\d|[01]?\d?\d)$"
)
_CIDR_RE = re.compile(
    r"^(?:(?:25[0-5]|2[0-4]\d|[01]?\d?\d)\.){3}(?:25[0-5]|2[0-4]\d|[01]?\d?\d)"
    r"/(?:[0-9]|[12]\d|3[0-2])$"
)


class NetworkConfigError(Exception):
    """Raised on validation or backend errors."""


def is_valid_ip(value: str) -> bool:
    return bool(_IP_RE.match(value or ""))


def is_valid_cidr(value: str) -> bool:
    return bool(_CIDR_RE.match(value or ""))


def get_network_config() -> dict:
    """Return the current IPv4 network config as a dict.

    Keys: backend, interface, connection, mode, address, gateway, dns.
    Backend is one of: NetworkManager, dhcpcd, unknown.
    """
    try:
        result = subprocess.run(
            ["sudo", HELPER_SCRIPT, "show"],
            capture_output=True,
            text=True,
            timeout=10,
        )
    except FileNotFoundError as exc:
        raise NetworkConfigError(
            "Network helper not installed. Run install.sh."
        ) from exc
    except subprocess.TimeoutExpired as exc:
        raise NetworkConfigError("Timeout reading network config") from exc

    if result.returncode != 0:
        raise NetworkConfigError(
            (result.stderr.strip() or result.stdout.strip())
            or f"helper exited {result.returncode}"
        )

    try:
        return json.loads(result.stdout.strip().splitlines()[-1])
    except (json.JSONDecodeError, IndexError) as exc:
        raise NetworkConfigError(f"Helper returned invalid JSON: {exc}") from exc


def _split_dns(dns: Optional[str | list[str]]) -> list[str]:
    if dns is None or dns == "":
        return []
    if isinstance(dns, list):
        items = dns
    else:
        items = [d.strip() for d in str(dns).split(",")]
    return [d for d in items if d]


def set_static_ip(
    interface: str,
    address: str,
    gateway: str,
    dns: Optional[str | list[str]] = None,
) -> str:
    """Apply a static IPv4 config to ``interface``.

    Args:
        interface: Network interface (e.g. wlan0).
        address: IPv4 with prefix length (e.g. 192.168.0.66/24).
        gateway: IPv4 of the default gateway.
        dns: CSV string or list of IPv4 DNS servers (optional).

    Returns:
        Helper stdout.
    """
    if not interface or not interface.strip():
        raise NetworkConfigError("interface is required")
    # Defensive: only allow safe interface name chars (no shell escapes)
    if not re.match(r"^[A-Za-z0-9_.-]{1,15}$", interface):
        raise NetworkConfigError(f"invalid interface name: {interface!r}")

    if not is_valid_cidr(address):
        raise NetworkConfigError(
            f"address must be IPv4 with prefix (e.g. 192.168.0.66/24); got {address!r}"
        )
    if not is_valid_ip(gateway):
        raise NetworkConfigError(f"invalid gateway: {gateway!r}")

    dns_list = _split_dns(dns)
    for d in dns_list:
        if not is_valid_ip(d):
            raise NetworkConfigError(f"invalid DNS server: {d!r}")
    dns_csv = ",".join(dns_list)

    cmd = ["sudo", HELPER_SCRIPT, "static", interface, address, gateway, dns_csv]
    logger.info(
        "set_static_ip: iface=%s addr=%s gw=%s dns=%s",
        interface, address, gateway, dns_csv or "(none)",
    )
    return _run(cmd)


def set_dhcp(interface: str) -> str:
    """Revert ``interface`` to DHCP."""
    if not re.match(r"^[A-Za-z0-9_.-]{1,15}$", interface or ""):
        raise NetworkConfigError(f"invalid interface name: {interface!r}")
    cmd = ["sudo", HELPER_SCRIPT, "dhcp", interface]
    logger.info("set_dhcp: iface=%s", interface)
    return _run(cmd)


def _run(cmd: list[str]) -> str:
    try:
        # Long timeout: nmcli con up can take ~10s while the link bounces.
        result = subprocess.run(
            cmd, capture_output=True, text=True, timeout=45,
        )
    except subprocess.TimeoutExpired as exc:
        raise NetworkConfigError("Network change timed out") from exc

    if result.returncode != 0:
        msg = (result.stderr.strip() or result.stdout.strip()
               or f"helper exited {result.returncode}")
        raise NetworkConfigError(msg)
    return result.stdout.strip()
