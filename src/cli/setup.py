"""CLI setup commands for print server management."""

import subprocess
import sys
from pathlib import Path


def run_command(cmd: list[str], check: bool = True) -> tuple[int, str, str]:
    """Run a shell command and return exit code, stdout, stderr."""
    try:
        result = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            check=check,
        )
        return result.returncode, result.stdout, result.stderr
    except subprocess.CalledProcessError as e:
        return e.returncode, e.stdout or "", e.stderr or ""
    except FileNotFoundError:
        return 127, "", f"Command not found: {cmd[0]}"


def check_service_status(service: str) -> dict:
    """Check the status of a systemd service."""
    code, stdout, stderr = run_command(
        ["systemctl", "is-active", service],
        check=False,
    )
    is_active = code == 0 and stdout.strip() == "active"

    code, stdout, stderr = run_command(
        ["systemctl", "is-enabled", service],
        check=False,
    )
    is_enabled = code == 0 and stdout.strip() == "enabled"

    return {
        "name": service,
        "active": is_active,
        "enabled": is_enabled,
    }


def check_cups_status() -> dict:
    """Check CUPS service status and configuration."""
    service = check_service_status("cups")

    # Check if CUPS is accessible
    code, stdout, stderr = run_command(["lpstat", "-r"], check=False)
    scheduler_running = "scheduler is running" in stdout.lower()

    # Get printer count
    code, stdout, stderr = run_command(["lpstat", "-p"], check=False)
    printer_lines = [l for l in stdout.strip().split("\n") if l.startswith("printer")]
    printer_count = len(printer_lines)

    return {
        **service,
        "scheduler_running": scheduler_running,
        "printer_count": printer_count,
    }


def check_avahi_status() -> dict:
    """Check Avahi service status."""
    service = check_service_status("avahi-daemon")

    # Check for published services
    code, stdout, stderr = run_command(
        ["avahi-browse", "-t", "_ipp._tcp", "-p"],
        check=False,
    )
    ipp_services = len([l for l in stdout.strip().split("\n") if l]) if code == 0 else 0

    return {
        **service,
        "ipp_services_published": ipp_services,
    }


def check_web_status() -> dict:
    """Check print server web interface status."""
    service = check_service_status("printserver-web")

    # Try to reach the health endpoint
    try:
        import urllib.request
        with urllib.request.urlopen("http://localhost:5000/health", timeout=5) as resp:
            health_ok = resp.status == 200
    except Exception:
        health_ok = False

    return {
        **service,
        "health_check_ok": health_ok,
    }


def check_network_status() -> dict:
    """Check network connectivity."""
    # Check WiFi interface
    code, stdout, stderr = run_command(["ip", "link", "show", "wlan0"], check=False)
    wlan_exists = code == 0

    # Get WiFi SSID if connected
    ssid = None
    if wlan_exists:
        code, stdout, stderr = run_command(["iwgetid", "wlan0", "-r"], check=False)
        if code == 0 and stdout.strip():
            ssid = stdout.strip()

    # Get IP address
    ip_address = None
    interface = "wlan0" if wlan_exists else "eth0"
    code, stdout, stderr = run_command(
        ["ip", "-4", "addr", "show", interface],
        check=False,
    )
    if code == 0:
        import re
        match = re.search(r"inet (\d+\.\d+\.\d+\.\d+)", stdout)
        if match:
            ip_address = match.group(1)

    return {
        "wifi_available": wlan_exists,
        "wifi_ssid": ssid,
        "ip_address": ip_address,
        "interface": interface,
    }


def status() -> None:
    """Print comprehensive status of the print server."""
    print("=" * 50)
    print("WiFi Print Server Status")
    print("=" * 50)

    # Network status
    print("\n[Network]")
    network = check_network_status()
    print(f"  Interface: {network['interface']}")
    print(f"  IP Address: {network['ip_address'] or 'Not assigned'}")
    if network["wifi_available"]:
        print(f"  WiFi SSID: {network['wifi_ssid'] or 'Not connected'}")

    # CUPS status
    print("\n[CUPS Print Service]")
    cups = check_cups_status()
    status_icon = "✓" if cups["active"] else "✗"
    print(f"  Service: {status_icon} {'Running' if cups['active'] else 'Stopped'}")
    print(f"  Enabled at boot: {'Yes' if cups['enabled'] else 'No'}")
    print(f"  Scheduler: {'Running' if cups['scheduler_running'] else 'Not running'}")
    print(f"  Printers configured: {cups['printer_count']}")

    # Avahi status
    print("\n[Avahi Discovery Service]")
    avahi = check_avahi_status()
    status_icon = "✓" if avahi["active"] else "✗"
    print(f"  Service: {status_icon} {'Running' if avahi['active'] else 'Stopped'}")
    print(f"  Enabled at boot: {'Yes' if avahi['enabled'] else 'No'}")
    print(f"  IPP services published: {avahi['ipp_services_published']}")

    # Web interface status
    print("\n[Web Interface]")
    web = check_web_status()
    status_icon = "✓" if web["active"] else "✗"
    print(f"  Service: {status_icon} {'Running' if web['active'] else 'Stopped'}")
    print(f"  Enabled at boot: {'Yes' if web['enabled'] else 'No'}")
    print(f"  Health check: {'OK' if web['health_check_ok'] else 'Failed'}")

    if network["ip_address"]:
        print(f"\n  Web UI: http://{network['ip_address']}:5000")
        print(f"  CUPS Admin: http://{network['ip_address']}:631")

    print("\n" + "=" * 50)

    # Overall status
    all_ok = (
        cups["active"]
        and cups["scheduler_running"]
        and avahi["active"]
        and network["ip_address"]
    )
    if all_ok:
        print("Status: ✓ Print server is operational")
    else:
        print("Status: ⚠ Some services need attention")


def reconfigure(component: str = "all") -> None:
    """Reconfigure print server components."""
    script_dir = Path(__file__).parent.parent.parent / "scripts"

    components = {
        "cups": "configure-cups.sh",
        "avahi": "configure-avahi.sh",
        "wifi": "configure-wifi.sh",
    }

    if component == "all":
        targets = list(components.keys())
    elif component in components:
        targets = [component]
    else:
        print(f"Unknown component: {component}")
        print(f"Available: {', '.join(components.keys())}, all")
        sys.exit(1)

    for target in targets:
        script = script_dir / components[target]
        if script.exists():
            print(f"Reconfiguring {target}...")
            code, stdout, stderr = run_command(
                ["sudo", "bash", str(script)],
                check=False,
            )
            if code == 0:
                print(f"  ✓ {target} reconfigured successfully")
            else:
                print(f"  ✗ {target} reconfiguration failed")
                if stderr:
                    print(f"    Error: {stderr}")
        else:
            print(f"  ⚠ Script not found: {script}")


def restart_services() -> None:
    """Restart all print server services."""
    services = ["cups", "avahi-daemon", "printserver-web"]

    for service in services:
        print(f"Restarting {service}...")
        code, stdout, stderr = run_command(
            ["sudo", "systemctl", "restart", service],
            check=False,
        )
        if code == 0:
            print(f"  ✓ {service} restarted")
        else:
            print(f"  ✗ {service} failed to restart")


def add_printer() -> None:
    """Interactive printer addition."""
    print("Detecting USB printers...")

    # List USB devices
    code, stdout, stderr = run_command(["lsusb"], check=False)
    if code == 0:
        print("\nUSB Devices:")
        for line in stdout.strip().split("\n"):
            print(f"  {line}")

    # Check CUPS detected printers
    print("\nCUPS detected printers:")
    code, stdout, stderr = run_command(
        ["lpinfo", "-v"],
        check=False,
    )
    if code == 0:
        usb_printers = [l for l in stdout.strip().split("\n") if "usb://" in l]
        if usb_printers:
            for printer in usb_printers:
                print(f"  {printer}")
        else:
            print("  No USB printers detected")
            print("\n  Troubleshooting:")
            print("  1. Ensure printer is connected via USB")
            print("  2. Check printer is powered on")
            print("  3. Try a different USB port")
    else:
        print("  Could not query CUPS for printers")

    print("\nTo add a printer manually, use the CUPS web interface:")
    print("  http://localhost:631/admin")


def main() -> None:
    """Main entry point for CLI."""
    import argparse

    parser = argparse.ArgumentParser(
        description="WiFi Print Server Setup and Management",
    )
    subparsers = parser.add_subparsers(dest="command", help="Commands")

    # Status command
    subparsers.add_parser("status", help="Show print server status")

    # Reconfigure command
    reconf_parser = subparsers.add_parser("reconfigure", help="Reconfigure components")
    reconf_parser.add_argument(
        "component",
        nargs="?",
        default="all",
        help="Component to reconfigure (cups, avahi, wifi, all)",
    )

    # Restart command
    subparsers.add_parser("restart", help="Restart all services")

    # Add printer command
    subparsers.add_parser("add-printer", help="Detect and add printers")

    args = parser.parse_args()

    if args.command == "status" or args.command is None:
        status()
    elif args.command == "reconfigure":
        reconfigure(args.component)
    elif args.command == "restart":
        restart_services()
    elif args.command == "add-printer":
        add_printer()
    else:
        parser.print_help()


if __name__ == "__main__":
    main()
