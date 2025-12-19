# Implementation Plan: WiFi Print Server

**Branch**: `001-wifi-print-server` | **Date**: 2025-12-18 | **Spec**: [spec.md](spec.md)
**Input**: Feature specification from `/specs/001-wifi-print-server/spec.md`

## Summary

Build a Raspberry Pi-based print server that connects a Brother USB printer to the network, enabling printing from Windows PCs, iOS devices (AirPrint), Android devices (IPP), and providing a web-based management interface. The system uses CUPS as the print spooler with Avahi for service discovery.

## Technical Context

**Language/Version**: Python 3.11 (web interface), Bash (setup scripts), Raspberry Pi OS (Debian-based)
**Primary Dependencies**: CUPS (print spooler), Avahi (mDNS/DNS-SD for AirPrint), Flask (web interface), cups-filters (AirPrint support)
**Storage**: CUPS internal database for print queue, SQLite for job history (optional)
**Testing**: pytest (Python), bats (Bash scripts), manual integration testing with real hardware
**Target Platform**: Raspberry Pi 3/4/Zero W running Raspberry Pi OS Lite (64-bit)
**Project Type**: Single embedded system with web frontend
**Performance Goals**: Web interface response <3s, print job submission <5s, startup <2min
**Constraints**: Limited RAM (1-4GB), must run headless, low power consumption, auto-recovery
**Scale/Scope**: Single printer, single household/small office (1-10 concurrent users)

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

| Principle | Status | Notes |
|-----------|--------|-------|
| I. Code Quality First | ✅ PASS | Python code follows PEP 8, clear naming, constants extracted |
| II. Test-Driven Development | ✅ PASS | Tests written for web interface and setup scripts; hardware mocked |
| III. Maintainability | ✅ PASS | Config externalized to `/etc/printserver/`, structured logging |
| IV. Modular Architecture | ✅ PASS | Layers: Hardware (CUPS) → Service (Python) → Web (Flask); DI used |
| V. Simplicity | ✅ PASS | Uses proven tools (CUPS, Avahi) instead of custom implementations |

**Quality Gates Compliance**:
- Unit tests: pytest for Python components
- Integration tests: Mocked CUPS interface for CI, real hardware for manual testing
- Linting: flake8/black for Python, shellcheck for Bash
- Documentation: README and quickstart included

## Project Structure

### Documentation (this feature)

```text
specs/001-wifi-print-server/
├── plan.md              # This file
├── research.md          # Phase 0 output
├── data-model.md        # Phase 1 output
├── quickstart.md        # Phase 1 output
├── contracts/           # Phase 1 output (API specs)
└── tasks.md             # Phase 2 output (/speckit.tasks)
```

### Source Code (repository root)

```text
src/
├── printserver/
│   ├── __init__.py
│   ├── config.py           # Configuration management
│   ├── cups_client.py      # CUPS integration layer
│   ├── printer.py          # Printer abstraction
│   └── job.py              # Print job model
├── web/
│   ├── __init__.py
│   ├── app.py              # Flask application
│   ├── routes.py           # API endpoints
│   ├── templates/          # Jinja2 HTML templates
│   │   ├── base.html
│   │   ├── dashboard.html
│   │   └── queue.html
│   └── static/             # CSS, JS assets
│       ├── style.css
│       └── app.js
└── cli/
    └── setup.py            # CLI setup commands

scripts/
├── install.sh              # Main installation script
├── configure-cups.sh       # CUPS configuration
├── configure-avahi.sh      # Avahi/AirPrint setup
└── configure-wifi.sh       # WiFi setup helper

config/
├── cups/
│   └── cupsd.conf.template
├── avahi/
│   └── airprint.service.template
└── systemd/
    └── printserver-web.service

tests/
├── unit/
│   ├── test_cups_client.py
│   ├── test_printer.py
│   └── test_job.py
├── integration/
│   ├── test_web_routes.py
│   └── test_cups_integration.py
└── conftest.py             # pytest fixtures
```

**Structure Decision**: Single project structure chosen because this is an embedded system with one deployment target. Web frontend is co-located with backend as it's a simple management interface, not a separate application.

## Complexity Tracking

No constitution violations requiring justification. The design uses standard, proven components:
- CUPS: Industry-standard print spooler with 25+ years of development
- Avahi: Standard mDNS implementation for Linux
- Flask: Minimal web framework appropriate for simple dashboard

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────┐
│                        Network Clients                          │
│  ┌─────────┐  ┌─────────┐  ┌─────────┐  ┌─────────┐            │
│  │ Windows │  │  iOS    │  │ Android │  │ Browser │            │
│  │   PC    │  │ Device  │  │ Device  │  │  (Any)  │            │
│  └────┬────┘  └────┬────┘  └────┬────┘  └────┬────┘            │
│       │            │            │            │                  │
│       │ SMB/IPP    │ AirPrint   │ IPP        │ HTTP            │
└───────┼────────────┼────────────┼────────────┼──────────────────┘
        │            │            │            │
        ▼            ▼            ▼            ▼
┌─────────────────────────────────────────────────────────────────┐
│                     Raspberry Pi Print Server                   │
│  ┌──────────────────────────────────────────────────────────┐  │
│  │                    Service Discovery                      │  │
│  │  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐       │  │
│  │  │    Avahi    │  │    Samba    │  │   Avahi     │       │  │
│  │  │  (AirPrint) │  │    (SMB)    │  │   (IPP)     │       │  │
│  │  └──────┬──────┘  └──────┬──────┘  └──────┬──────┘       │  │
│  └─────────┼────────────────┼────────────────┼──────────────┘  │
│            │                │                │                  │
│            ▼                ▼                ▼                  │
│  ┌──────────────────────────────────────────────────────────┐  │
│  │                         CUPS                              │  │
│  │              (Print Spooler & Queue Manager)              │  │
│  └──────────────────────────┬───────────────────────────────┘  │
│                             │                                   │
│  ┌──────────────────────────┼───────────────────────────────┐  │
│  │                    Web Interface                          │  │
│  │  ┌─────────────┐         │         ┌─────────────┐       │  │
│  │  │    Flask    │◄────────┴────────►│  CUPS API   │       │  │
│  │  │   (HTTP)    │                   │  (pycups)   │       │  │
│  │  └─────────────┘                   └─────────────┘       │  │
│  └──────────────────────────────────────────────────────────┘  │
│                             │                                   │
│                             ▼                                   │
│  ┌──────────────────────────────────────────────────────────┐  │
│  │                    USB Interface                          │  │
│  │                  (Brother Printer)                        │  │
│  └──────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────┘
```

## Key Technical Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Print Spooler | CUPS | Industry standard, built-in driver support, AirPrint compatible |
| Service Discovery | Avahi | Standard mDNS for Linux, required for AirPrint |
| Web Framework | Flask | Lightweight, sufficient for simple dashboard |
| Windows Support | Samba + IPP | Native Windows printer sharing protocol |
| Configuration | INI files | Simple, editable without code knowledge |
| Process Management | systemd | Standard for Raspberry Pi OS, auto-restart |

## Risk Assessment

| Risk | Likelihood | Impact | Mitigation |
|------|------------|--------|------------|
| Brother driver not available | Low | High | Use generic drivers; document specific model support |
| WiFi instability | Medium | Medium | Auto-reconnect logic; status monitoring |
| CUPS configuration complexity | Medium | Medium | Pre-configured templates; setup wizard |
| Resource constraints on Pi Zero | Medium | Low | Test on lowest-spec hardware; optimize memory usage |
