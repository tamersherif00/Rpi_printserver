# Rpi_printserver Development Guidelines

Auto-generated from all feature plans. Last updated: 2025-12-18

## Active Technologies

- Python 3.11 (web interface), Bash (setup scripts), Raspberry Pi OS (Debian-based) + CUPS (print spooler), Avahi (mDNS/DNS-SD for AirPrint), Flask (web interface), cups-filters (AirPrint support) (001-wifi-print-server)

## Project Structure

```text
backend/
frontend/
tests/
```

## Commands

cd src; pytest; ruff check .

## Versioning

**IMPORTANT:** On every commit that changes functionality, increment the version
in `src/printserver/version.py` — update `VERSION` (semver), `RELEASE_DATE`
(YYYY-MM-DD), and `RELEASE_NOTES` (one-line summary of what changed).
Also update `version` in `pyproject.toml` to match.

## Code Style

Python 3.11 (web interface), Bash (setup scripts), Raspberry Pi OS (Debian-based): Follow standard conventions

## Recent Changes

- 001-wifi-print-server: Added Python 3.11 (web interface), Bash (setup scripts), Raspberry Pi OS (Debian-based) + CUPS (print spooler), Avahi (mDNS/DNS-SD for AirPrint), Flask (web interface), cups-filters (AirPrint support)

<!-- MANUAL ADDITIONS START -->
## Windows Printing — Fully Functional (2026-03-04)

Verified working on Windows 10/11 against a Raspberry Pi at 192.168.0.65.

### What was fixed

| Issue | Fix |
|---|---|
| `net view` error 53 / no SMB path | wsdd + nmbd broadcasting on UDP 137/138 |
| `net use` error 1272 (guest blocked) | `configure-samba.sh` creates Samba user `printuser`/`printserver` |
| Printer not discovered by Windows | `hotplug-printer.sh` runs `lpadmin -m everywhere` on USB connect, enabling Avahi/mDNS advertisement |
| wsdd missing `-w WORKGROUP` (apt install) | `install.sh` creates `/etc/systemd/system/wsdd.service.d/printserver.conf` drop-in |

### How discovery works

1. Plug in USB printer → udev fires → `hotplug-printer.sh add`
2. Script waits for CUPS, adds driverless queue, marks it shared
3. `configure-avahi.sh` runs → CUPS advertises printer via mDNS (port 631)
4. Windows auto-discovers in **Settings → Printers & scanners**

### Windows connection options

- **IPP (recommended, no password):** `http://192.168.0.65:631/printers/<name>`
- **SMB browse:** `\\192.168.0.65` → username `printuser`, password `printserver`
- Change default password: `sudo smbpasswd printuser`
<!-- MANUAL ADDITIONS END -->
