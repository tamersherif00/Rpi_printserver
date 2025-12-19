# Research: WiFi Print Server

**Feature**: 001-wifi-print-server
**Date**: 2025-12-18

## Research Topics

### 1. CUPS Configuration for Network Printing

**Decision**: Use CUPS 2.x with IPP Everywhere support

**Rationale**:
- CUPS is the de facto standard print system for Linux/Unix
- Built-in support for IPP (Internet Printing Protocol) which is required for AirPrint and Android
- Extensive driver database including Brother printers
- Well-documented API accessible via Python (pycups library)

**Alternatives Considered**:
- LPD/LPR: Legacy protocol, limited features, no AirPrint support
- Custom print spooler: Unnecessary complexity, reinventing the wheel
- p910nd: Too simple, no queue management or web interface

**Configuration Approach**:
```
# /etc/cups/cupsd.conf key settings
Listen *:631                    # Allow network connections
Browsing On                     # Enable printer browsing
BrowseLocalProtocols dnssd      # Use DNS-SD for discovery
DefaultAuthType Basic           # Simple authentication
WebInterface Yes                # Enable CUPS web admin
```

### 2. AirPrint Implementation

**Decision**: Use Avahi daemon with DNS-SD service definition

**Rationale**:
- Apple AirPrint uses DNS-SD (Bonjour) for printer discovery
- Avahi is the standard mDNS/DNS-SD implementation for Linux
- cups-filters package includes AirPrint support out of the box
- No proprietary Apple software required

**Alternatives Considered**:
- cups-browsed alone: Less reliable discovery
- Manual Bonjour configuration: More complex, same result
- Third-party AirPrint bridges: Unnecessary additional dependency

**Service Definition**:
```xml
<!-- /etc/avahi/services/AirPrint-BrotherPrinter.service -->
<service-group>
  <name>Brother Printer @ PrintServer</name>
  <service>
    <type>_ipp._tcp</type>
    <subtype>_universal._sub._ipp._tcp</subtype>
    <port>631</port>
    <txt-record>txtvers=1</txt-record>
    <txt-record>qtotal=1</txt-record>
    <txt-record>rp=printers/Brother</txt-record>
    <txt-record>pdl=application/pdf,image/jpeg,image/png</txt-record>
    <txt-record>URF=DM3</txt-record>
  </service>
</service-group>
```

### 3. Windows Printing Support

**Decision**: IPP over HTTP (CUPS native) + optional Samba for legacy support

**Rationale**:
- Windows 10/11 natively supports IPP printing
- Users can add printer via `http://[pi-ip]:631/printers/[name]`
- Samba provides SMB protocol for older Windows versions
- Both protocols can run simultaneously

**Alternatives Considered**:
- Samba only: Requires more configuration, older protocol
- IPP only: May not work with very old Windows versions
- Windows Print Server: Not applicable (Linux-based solution)

**Windows Setup Path**:
1. Settings → Printers & Scanners → Add printer
2. "The printer I want isn't listed"
3. "Add printer using TCP/IP address"
4. Enter `http://[raspberry-pi-ip]:631/printers/Brother`

### 4. Brother Printer Driver Selection

**Decision**: Use brother-cups-wrapper or generic PCL/PS driver

**Rationale**:
- Brother provides official Linux drivers (brother-cups-wrapper packages)
- Most Brother printers also support generic PCL or PostScript
- CUPS includes generic drivers that work with most USB printers
- Fallback to generic driver if specific driver unavailable

**Alternatives Considered**:
- Generic drivers only: May lose advanced features
- GutenPrint: Good alternative, wide compatibility
- Proprietary drivers: Already covered by brother-cups-wrapper

**Driver Priority**:
1. Official Brother driver (if available for model)
2. GutenPrint driver (wide compatibility)
3. Generic PCL/PostScript driver (basic functionality)

### 5. Web Interface Framework

**Decision**: Flask with Jinja2 templates, minimal JavaScript

**Rationale**:
- Flask is lightweight and well-suited for embedded systems
- Minimal resource usage compared to Django or FastAPI
- Jinja2 templates enable server-side rendering (faster on Pi)
- Bootstrap CSS for responsive design without complex build tools

**Alternatives Considered**:
- Django: Too heavy for simple dashboard
- FastAPI: Async not needed, adds complexity
- Node.js/Express: Different language stack, more memory
- Static HTML + API: More complex, requires client-side JS framework

**Key Endpoints**:
| Endpoint | Method | Purpose |
|----------|--------|---------|
| `/` | GET | Dashboard with printer status |
| `/queue` | GET | View print queue |
| `/api/status` | GET | JSON printer status |
| `/api/jobs` | GET | JSON job list |
| `/api/jobs/<id>` | DELETE | Cancel job |

### 6. Auto-start and Service Management

**Decision**: systemd service units

**Rationale**:
- systemd is standard on Raspberry Pi OS
- Provides automatic restart on failure
- Dependency management (start after network)
- Standard logging via journald

**Alternatives Considered**:
- init.d scripts: Legacy, less features
- supervisor: Additional dependency
- Docker: Overkill for single-purpose device

**Service Definition**:
```ini
# /etc/systemd/system/printserver-web.service
[Unit]
Description=Print Server Web Interface
After=network.target cups.service
Requires=cups.service

[Service]
Type=simple
User=printserver
ExecStart=/usr/bin/python3 /opt/printserver/web/app.py
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
```

### 7. WiFi Configuration Approach

**Decision**: Use wpa_supplicant with optional setup wizard

**Rationale**:
- wpa_supplicant is standard on Raspberry Pi OS
- Can be pre-configured via wpa_supplicant.conf on SD card
- Setup wizard can modify config and restart service
- NetworkManager is overkill for static WiFi connection

**Alternatives Considered**:
- NetworkManager: More complex, higher resource usage
- ConnMan: Less common, smaller community
- Custom WiFi manager: Unnecessary development effort

**Setup Options**:
1. Pre-configure: Edit `wpa_supplicant.conf` before first boot
2. Setup wizard: Web interface on initial boot (AP mode)
3. SSH access: Manual configuration via command line

### 8. Security Considerations

**Decision**: Local network only, optional basic auth

**Rationale**:
- Print server intended for trusted home/office network
- CUPS has built-in access control by IP range
- Basic authentication available for web interface
- No internet exposure required or recommended

**Implementation**:
- CUPS access limited to local subnet
- Web interface optionally password-protected
- No sensitive data stored (just print jobs)
- Firewall rules to restrict access if needed

## Summary of Technology Stack

| Component | Technology | Purpose |
|-----------|------------|---------|
| OS | Raspberry Pi OS Lite (64-bit) | Base system |
| Print Spooler | CUPS 2.x | Print queue management |
| Discovery | Avahi | mDNS/DNS-SD for AirPrint |
| Windows Support | CUPS IPP + Samba | Network printer protocols |
| Web Interface | Flask + Jinja2 | Management dashboard |
| CSS Framework | Bootstrap 5 | Responsive design |
| Process Manager | systemd | Service lifecycle |
| WiFi | wpa_supplicant | Network connectivity |
| Python Libs | pycups, flask | CUPS API, web server |
