# Quickstart: WiFi Print Server

Get your Raspberry Pi print server up and running in 15 minutes.

## Prerequisites

- Raspberry Pi 3, 4, or Zero W (with WiFi)
- MicroSD card (8GB minimum)
- Brother USB printer
- USB-A to USB-B cable
- Power supply for Raspberry Pi
- Computer with SD card reader (for initial setup)

## Installation Steps

### Step 1: Prepare the SD Card

1. Download [Raspberry Pi Imager](https://www.raspberrypi.com/software/)
2. Insert SD card into your computer
3. Open Raspberry Pi Imager
4. Choose OS: **Raspberry Pi OS Lite (64-bit)**
5. Click the gear icon for advanced options:
   - Enable SSH
   - Set username/password
   - Configure WiFi (SSID and password)
   - Set hostname: `printserver`
6. Write to SD card

### Step 2: Connect Hardware

1. Insert SD card into Raspberry Pi
2. Connect Brother printer via USB cable
3. Connect power to Raspberry Pi
4. Wait 2 minutes for boot

### Step 3: Install Print Server Software

From your computer, open a terminal and SSH into the Pi:

```bash
ssh pi@printserver.local
# Enter password when prompted
```

Run the installation script:

```bash
curl -sSL https://raw.githubusercontent.com/[repo]/main/scripts/install.sh | bash
```

The script will:
- Install CUPS, Avahi, and dependencies
- Configure the print server
- Set up the web interface
- Enable auto-start services

Installation takes approximately 5-10 minutes.

### Step 4: Verify Installation

1. Open a web browser
2. Navigate to: `http://printserver.local:5000`
3. You should see the print server dashboard
4. Verify printer shows as "Ready"

## Adding the Printer

### Windows 10/11

1. Open **Settings** → **Bluetooth & devices** → **Printers & scanners**
2. Click **Add device**
3. Wait for "Brother @ PrintServer" to appear
4. Click **Add device**

*Alternative manual method:*
1. Click **Add device** → **Add manually**
2. Select "Add a printer using TCP/IP address"
3. Enter: `http://printserver.local:631/printers/Brother`
4. Click **Next** and follow prompts

### iPhone/iPad (AirPrint)

1. Open any app with content to print
2. Tap **Share** → **Print**
3. Tap **Select Printer**
4. Choose "Brother @ PrintServer"
5. Tap **Print**

### Android

1. Open any app with content to print
2. Tap **Menu** → **Print**
3. Select "Brother @ PrintServer"
4. Tap **Print**

*Note: Some Android devices may need the "Default Print Service" enabled in Settings.*

## Troubleshooting

### Printer not detected

1. Check USB cable connection
2. Verify printer is powered on
3. SSH into Pi and run: `lpstat -p`
4. If no printer listed, run: `sudo lpadmin -p Brother -E -v usb://Brother`

### Cannot access web interface

1. Verify Pi is on network: `ping printserver.local`
2. Check service status: `sudo systemctl status printserver-web`
3. View logs: `sudo journalctl -u printserver-web -f`

### Windows cannot find printer

1. Ensure Pi and Windows PC are on same network
2. Try IP address instead: `http://[pi-ip-address]:631/printers/Brother`
3. Find IP: SSH to Pi and run `hostname -I`

### AirPrint not working

1. Verify Avahi is running: `sudo systemctl status avahi-daemon`
2. Check service published: `avahi-browse -a | grep ipp`
3. Restart Avahi: `sudo systemctl restart avahi-daemon`

### Print job stuck

1. Open web interface: `http://printserver.local:5000/queue`
2. Click **Cancel** on stuck job
3. Or via command line: `cancel -a`

## Configuration Files

| File | Purpose |
|------|---------|
| `/etc/cups/cupsd.conf` | CUPS main configuration |
| `/etc/cups/printers.conf` | Printer definitions |
| `/etc/avahi/services/*.service` | AirPrint service definitions |
| `/etc/printserver/config.ini` | Web interface settings |

## Useful Commands

```bash
# Restart print services
sudo systemctl restart cups
sudo systemctl restart avahi-daemon
sudo systemctl restart printserver-web

# View print queue
lpstat -o

# Cancel all jobs
cancel -a

# Check printer status
lpstat -p -d

# View CUPS web interface (admin)
# Navigate to http://printserver.local:631

# View system logs
sudo journalctl -u cups -f
```

## Next Steps

- Set up a static IP address for reliable printer access
- Configure printer sharing name in `/etc/printserver/config.ini`
- Enable HTTPS for web interface (optional)
- Set up automatic updates
