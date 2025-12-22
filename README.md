# Raspberry Pi WiFi Print Server

Transform your old USB printer into a wireless print server using a Raspberry Pi. Print from Windows, macOS, iOS, and Android devices on your local network.

## Features

- **Universal Printing**: Print from any device on your network
  - Windows 10/11 via IPP or SMB
  - macOS via AirPrint
  - iOS via AirPrint (native)
  - Android via IPP Everywhere
- **Web Interface**: Monitor printer status and manage print queue
- **Auto-Discovery**: Printers appear automatically on your devices
- **Reliable**: Auto-recovery from restarts and USB disconnections
- **Easy Setup**: Install in under 15 minutes

## Requirements

### Supported Raspberry Pi Models
- **Raspberry Pi 5** - Best performance
- **Raspberry Pi 4** (all RAM variants) - Recommended
- **Raspberry Pi 3B/3B+** - Good performance
- **Raspberry Pi Zero 2 W** - Compact option with WiFi

> Note: Original Pi Zero W is not recommended due to limited performance.

### Supported Printers
**Brother Printers** (primary target):
- HL-L2300 series, HL-L2340, HL-L2350, HL-L2360, HL-L2370, HL-L2390
- DCP-L2500 series, DCP-L2520, DCP-L2540
- MFC-L2700 series, MFC-L2710, MFC-L2750
- Most Brother laser printers work with the included `brlaser` driver

**Other USB Printers**:
- HP, Canon, Epson via Gutenprint drivers
- Any printer supporting IPP Everywhere (driverless)

### Hardware
- One of the supported Raspberry Pi models above
- MicroSD card (8GB minimum, 16GB recommended)
- USB cable (USB-A to USB-B typically for printers)
- USB printer

### Software
- Raspberry Pi OS Lite (64-bit recommended for Pi 4/5, 32-bit for Zero 2 W)
- Internet connection for initial setup

## Quick Start

### 1. Prepare Your Raspberry Pi

Flash Raspberry Pi OS to your SD card using [Raspberry Pi Imager](https://www.raspberrypi.com/software/):
- Enable SSH
- Set hostname to `printserver`
- Configure WiFi credentials

### 2. Connect Your Printer

1. Insert SD card into Raspberry Pi
2. Connect printer via USB
3. Power on both devices
4. Wait for boot (~2 minutes)

### 3. Install the Print Server

SSH into your Pi and run:

```bash
ssh pi@printserver.local

# Clone and install
git clone https://github.com/your-username/rpi-printserver.git
cd rpi-printserver
sudo ./scripts/install.sh
```

### 4. Add Your Printer

**Windows 10/11:**
1. Settings → Bluetooth & devices → Printers & scanners
2. Add device → Your printer should appear
3. Or manually: `http://printserver.local:631/printers/YourPrinter`

**iPhone/iPad:**
1. Share → Print → Select Printer
2. Your printer appears automatically via AirPrint

**Android:**
1. Settings → Connected devices → Printing
2. Enable Default Print Service
3. Your printer appears in any app's print menu

## Web Interface

Access the management interface at `http://printserver.local:5000`

**Features:**
- View printer status and server health
- Monitor print queue and cancel jobs
- Change print server hostname
- Real-time status updates

**Pages:**
- **Dashboard** (`/`): Overview of printers and server status
- **Print Queue** (`/queue`): Active and completed print jobs
- **Settings** (`/settings`): Change hostname and system settings

## Project Structure

```
rpi-printserver/
├── src/
│   ├── printserver/      # Core Python modules
│   │   ├── config.py     # Configuration management
│   │   ├── cups_client.py # CUPS integration
│   │   ├── printer.py    # Printer model
│   │   └── job.py        # Print job model
│   ├── web/              # Flask web interface
│   │   ├── app.py        # Application factory
│   │   ├── routes.py     # API and page routes
│   │   ├── templates/    # HTML templates
│   │   └── static/       # CSS and JavaScript
│   └── cli/              # Command-line tools
├── scripts/              # Installation scripts
├── config/               # Configuration templates
├── tests/                # Unit and integration tests
└── specs/                # Design documents
```

## API Endpoints

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/api/status` | GET | Server and printer status |
| `/api/printers` | GET | List all printers |
| `/api/printers/{name}` | GET | Printer details |
| `/api/jobs` | GET | List print jobs |
| `/api/jobs/{id}` | GET | Job details |
| `/api/jobs/{id}` | DELETE | Cancel a job |
| `/api/system/hostname` | GET | Get current hostname |
| `/api/system/hostname` | POST | Change hostname |
| `/api/system/hostname/validate` | POST | Validate hostname |
| `/health` | GET | Health check |

## Configuration

Configuration file: `/etc/printserver/config.ini`

```ini
[web]
host = 0.0.0.0
port = 5000
debug = false

[cups]
host = localhost
port = 631

[server]
log_level = INFO
printer_name = Brother_HL-L2350DW
```

## Troubleshooting

### Printer Not Detected

```bash
# Check USB connection
lsusb

# Check CUPS detection
sudo lpinfo -v

# Manually add printer
sudo lpadmin -p MyPrinter -E -v usb://... -m everywhere
```

### Cannot Access Web Interface

```bash
# Check service status
sudo systemctl status printserver-web

# View logs
sudo journalctl -u printserver-web -f
```

### AirPrint Not Working

```bash
# Verify Avahi
systemctl status avahi-daemon

# Check published services
avahi-browse -t _ipp._tcp

# Regenerate services
sudo ./scripts/configure-avahi.sh
```

### Brother Printer Driver Issues

The installer includes the open-source `brlaser` driver which works with many Brother laser printers. If your printer isn't working:

```bash
# Check if printer is detected
sudo lpinfo -v | grep Brother

# Check installed drivers
lpinfo -m | grep -i brother

# If brlaser doesn't support your model, install Brother's official driver:
# 1. Go to https://support.brother.com
# 2. Find your printer model
# 3. Download "Linux (deb)" driver
# 4. Or use the Driver Install Tool:
wget https://download.brother.com/welcome/dlf006893/linux-brprinter-installer-2.2.3-1.gz
gunzip linux-brprinter-installer-*.gz
sudo bash linux-brprinter-installer-* HL-L2350DW  # Replace with your model
```

**Supported by brlaser** (no additional driver needed):
- HL-L2300D, HL-L2320D, HL-L2340DW, HL-L2350DW, HL-L2360D/DW, HL-L2370DW, HL-L2390DW
- DCP-L2500D, DCP-L2520DW, DCP-L2540DW
- MFC-L2700DW, MFC-L2710DW, MFC-L2750DW
- And many more (check `lpinfo -m | grep brlaser`)

## Development

### Setup Development Environment

```bash
# Create virtual environment
python3 -m venv .venv
source .venv/bin/activate

# Install dependencies
pip install -e ".[dev]"

# Run tests
pytest

# Run linting
ruff check .
black --check .
```

### Running Locally

```bash
# Set environment variables
export FLASK_APP=web.app
export FLASK_ENV=development

# Run Flask development server
flask run --host=0.0.0.0
```

## Contributing

1. Fork the repository
2. Create a feature branch
3. Make your changes
4. Run tests (`pytest`)
5. Submit a pull request

## License

MIT License - see [LICENSE](LICENSE) for details.

## Acknowledgments

- [CUPS](https://www.cups.org/) - The printing system
- [Avahi](https://avahi.org/) - mDNS/DNS-SD implementation
- [Flask](https://flask.palletsprojects.com/) - Web framework
- [pycups](https://github.com/OpenPrinting/pycups) - Python CUPS bindings
