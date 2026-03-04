"""Wake-on-LAN: magic packet sender and saved-device store."""

import json
import logging
import re
import socket
import uuid
from pathlib import Path

logger = logging.getLogger(__name__)

# Stored under /var/lib/printserver/ which is writable even with
# ProtectSystem=strict (see ReadWritePaths in the systemd unit).
WOL_DEVICES_FILE = Path("/var/lib/printserver/wol_devices.json")

# Magic packet is broadcast via UDP to port 9 (discard) or 7 (echo).
WOL_PORT = 9


# ── MAC validation ────────────────────────────────────────────────────────────

_MAC_RE = re.compile(r"^([0-9A-Fa-f]{2}[:\-.]?){5}[0-9A-Fa-f]{2}$")


def normalise_mac(mac: str) -> str:
    """Return upper-case colon-separated MAC, e.g. 'AA:BB:CC:DD:EE:FF'.

    Accepts any common delimiter (colon, hyphen, dot, none).
    Raises ValueError for invalid input.
    """
    clean = re.sub(r"[^0-9A-Fa-f]", "", mac)
    if len(clean) != 12:
        raise ValueError(f"Invalid MAC address: {mac!r}")
    return ":".join(clean[i:i+2].upper() for i in range(0, 12, 2))


# ── Magic packet ──────────────────────────────────────────────────────────────

def send_magic_packet(mac: str, broadcast: str = "255.255.255.255") -> None:
    """Broadcast a WOL magic packet for *mac* to *broadcast*:9.

    The magic packet is 6 × 0xFF followed by 16 repetitions of the
    6-byte MAC address (102 bytes total), sent over UDP.

    Raises ValueError for an invalid MAC, OSError on socket failure.
    """
    mac_norm = normalise_mac(mac)
    mac_bytes = bytes.fromhex(mac_norm.replace(":", ""))
    payload = b"\xff" * 6 + mac_bytes * 16

    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
        sock.connect((broadcast, WOL_PORT))
        sock.send(payload)

    logger.info("WOL magic packet sent to %s (broadcast %s)", mac_norm, broadcast)


# ── Device store (JSON file) ──────────────────────────────────────────────────

def _load() -> list[dict]:
    if WOL_DEVICES_FILE.exists():
        try:
            return json.loads(WOL_DEVICES_FILE.read_text())
        except (json.JSONDecodeError, OSError) as exc:
            logger.warning("Could not read WOL devices file: %s", exc)
    return []


def _save(devices: list[dict]) -> None:
    WOL_DEVICES_FILE.parent.mkdir(parents=True, exist_ok=True)
    WOL_DEVICES_FILE.write_text(json.dumps(devices, indent=2))


def list_devices() -> list[dict]:
    """Return all saved WOL devices, sorted by name."""
    return sorted(_load(), key=lambda d: d.get("name", "").lower())


def add_device(name: str, mac: str, ip: str = "") -> dict:
    """Validate, store, and return a new WOL device entry.

    Raises ValueError if *name* or *mac* are invalid.
    """
    name = name.strip()
    ip = ip.strip()
    if not name:
        raise ValueError("Device name is required")
    mac_norm = normalise_mac(mac)   # raises ValueError if bad

    device = {
        "id": str(uuid.uuid4()),
        "name": name,
        "mac": mac_norm,
        "ip": ip,
    }
    devices = _load()
    devices.append(device)
    _save(devices)
    logger.info("WOL device saved: %s (%s)", name, mac_norm)
    return device


def remove_device(device_id: str) -> bool:
    """Delete the device with *device_id*. Returns True if it existed."""
    devices = _load()
    updated = [d for d in devices if d["id"] != device_id]
    if len(updated) == len(devices):
        return False
    _save(updated)
    return True
