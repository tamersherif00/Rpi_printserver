"""Flask routes for the print server web interface."""

import logging
import socket
import subprocess
import time
from datetime import datetime
from typing import Any

from flask import Flask, jsonify, render_template, request

from printserver.cups_client import CupsClient, CupsClientError
from printserver.printer import get_all_printers, get_printer
from printserver.job import get_all_jobs, get_job, cancel_job as cancel_print_job
from printserver.system_utils import (
    get_hostname,
    set_hostname,
    validate_hostname,
    requires_root,
    SystemUtilsError,
)

logger = logging.getLogger(__name__)

# Allowed services for log viewing (whitelist to prevent command injection)
ALLOWED_LOG_SERVICES = {"printserver-web", "cups", "avahi-daemon", "app", "cups-error"}

# Allowed services for restart (whitelist to prevent arbitrary service control)
ALLOWED_RESTART_SERVICES = {"cups", "avahi-daemon", "printserver-web"}

# Path to the restart helper script
RESTART_SCRIPT = "/opt/printserver/scripts/restart-service.sh"

# Simple TTL cache for expensive subprocess-heavy functions
_cache: dict[str, tuple[float, Any]] = {}


def _cached_call(key: str, fn, ttl_seconds: float):
    """Return cached result if fresh, otherwise call fn() and cache it."""
    now = time.monotonic()
    if key in _cache:
        cached_time, cached_value = _cache[key]
        if now - cached_time < ttl_seconds:
            return cached_value
    result = fn()
    _cache[key] = (now, result)
    return result


def get_cups_client(app: Flask) -> CupsClient:
    """Get a self-healing singleton CUPS client.

    Creates the client once and reuses it. The client's ensure_connected()
    handles reconnection with retry on each use.

    Args:
        app: Flask application.

    Returns:
        Connected CupsClient instance.
    """
    if not hasattr(app, "_cups_client") or app._cups_client is None:
        app._cups_client = CupsClient(
            host=app.config.get("CUPS_HOST", "localhost"),
            port=app.config.get("CUPS_PORT", 631),
        )
    app._cups_client.ensure_connected()
    return app._cups_client


def _get_ip_address() -> str:
    """Get the primary IP address without requiring internet access.

    Uses hostname -I (local, instant) as primary method.
    Falls back to socket with a short timeout.

    Returns:
        IP address string, or 127.0.0.1 if unavailable.
    """
    # Method 1: hostname -I (works without internet, instant)
    try:
        result = subprocess.run(
            ["hostname", "-I"],
            capture_output=True,
            text=True,
            timeout=2,
        )
        if result.returncode == 0:
            ips = result.stdout.strip().split()
            if ips:
                return ips[0]
    except Exception:
        pass

    # Method 2: Socket with 2s timeout (fallback)
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.settimeout(2)
        s.connect(("8.8.8.8", 80))
        ip = s.getsockname()[0]
        s.close()
        return ip
    except Exception:
        return "127.0.0.1"


def get_server_status() -> dict[str, Any]:
    """Get overall server status information.

    Returns:
        Dictionary with server status.
    """
    hostname = socket.gethostname()
    ip_address = _get_ip_address()

    # Get uptime
    try:
        with open("/proc/uptime", "r") as f:
            uptime = int(float(f.read().split()[0]))
    except Exception:
        uptime = 0

    # Check if CUPS is running (default False on error - don't lie about status)
    try:
        result = subprocess.run(
            ["systemctl", "is-active", "cups"],
            capture_output=True,
            text=True,
            timeout=3,
        )
        cups_running = result.stdout.strip() == "active"
    except Exception as e:
        cups_running = False
        logger.warning(f"Could not check CUPS status: {e}")

    # Check if Avahi is running (default False on error)
    try:
        result = subprocess.run(
            ["systemctl", "is-active", "avahi-daemon"],
            capture_output=True,
            text=True,
            timeout=3,
        )
        avahi_running = result.stdout.strip() == "active"
    except Exception as e:
        avahi_running = False
        logger.warning(f"Could not check Avahi status: {e}")

    # Get WiFi status
    wifi_connected = False
    wifi_ssid = ""
    wifi_signal = 0

    try:
        result = subprocess.run(
            ["iwgetid", "-r"],
            capture_output=True,
            text=True,
            timeout=3,
        )
        if result.returncode == 0:
            wifi_ssid = result.stdout.strip()
            wifi_connected = bool(wifi_ssid)

        # Get signal strength
        result = subprocess.run(
            ["iwconfig", "wlan0"],
            capture_output=True,
            text=True,
            timeout=3,
        )
        if "Signal level" in result.stdout:
            for line in result.stdout.split("\n"):
                if "Signal level" in line:
                    if "%" in line:
                        wifi_signal = int(line.split("%")[0].split("=")[-1])
                    break
    except Exception:
        pass

    return {
        "hostname": hostname,
        "ip_address": ip_address,
        "uptime": uptime,
        "cups_running": cups_running,
        "avahi_running": avahi_running,
        "wifi_connected": wifi_connected,
        "wifi_ssid": wifi_ssid,
        "wifi_signal": wifi_signal,
    }


def _get_service_status(service: str) -> dict[str, Any]:
    """Get detailed systemd service status.

    Args:
        service: systemd service name.

    Returns:
        Dictionary with service state details.
    """
    info = {"name": service, "active": False, "state": "unknown", "since": ""}
    try:
        result = subprocess.run(
            ["systemctl", "show", service,
             "--property=ActiveState,SubState,StateChangeTimestamp"],
            capture_output=True, text=True, timeout=3,
        )
        if result.returncode == 0:
            for line in result.stdout.strip().split("\n"):
                if "=" in line:
                    key, val = line.split("=", 1)
                    if key == "ActiveState":
                        info["state"] = val
                        info["active"] = val == "active"
                    elif key == "SubState":
                        info["sub_state"] = val
                    elif key == "StateChangeTimestamp":
                        info["since"] = val
    except Exception as e:
        logger.warning(f"Could not get status for {service}: {e}")
    return info


def _get_system_diagnostics() -> dict[str, Any]:
    """Gather comprehensive system diagnostics.

    Returns:
        Dictionary with services, network, hardware, and storage info.
    """
    diag: dict[str, Any] = {"timestamp": datetime.now().isoformat()}

    # Services
    diag["services"] = {
        "cups": _get_service_status("cups"),
        "avahi": _get_service_status("avahi-daemon"),
        "printserver": _get_service_status("printserver-web"),
    }

    # CUPS connectivity
    diag["cups_connection"] = {"reachable": False, "scheduler_running": False}
    try:
        result = subprocess.run(
            ["lpstat", "-r"], capture_output=True, text=True, timeout=5,
        )
        if result.returncode == 0 and "running" in result.stdout.lower():
            diag["cups_connection"]["reachable"] = True
            diag["cups_connection"]["scheduler_running"] = True
    except Exception:
        pass

    # AirPrint discovery (check if printers are advertised via mDNS)
    diag["airprint_services"] = []
    try:
        result = subprocess.run(
            ["avahi-browse", "-t", "_ipp._tcp", "-p"],
            capture_output=True, text=True, timeout=3,
        )
        if result.returncode == 0 and result.stdout.strip():
            for line in result.stdout.strip().split("\n"):
                # Parseable format: +;interface;protocol;name;type;domain
                parts = line.split(";")
                if len(parts) >= 4 and parts[0] == "+":
                    service_name = parts[3]
                    if service_name and service_name not in diag["airprint_services"]:
                        diag["airprint_services"].append(service_name)
    except FileNotFoundError:
        diag["airprint_services"] = []
    except Exception:
        pass

    # USB printers detected
    diag["usb_printers"] = []
    try:
        result = subprocess.run(
            ["lsusb"], capture_output=True, text=True, timeout=5,
        )
        if result.returncode == 0:
            for line in result.stdout.strip().split("\n"):
                lower = line.lower()
                if any(kw in lower for kw in ["printer", "brother", "hp ", "epson",
                                                "canon", "xerox", "samsung"]):
                    diag["usb_printers"].append(line.strip())
    except Exception:
        pass

    # Network
    diag["network"] = {
        "ip_address": _get_ip_address(),
        "hostname": socket.gethostname(),
    }
    try:
        result = subprocess.run(
            ["iwgetid", "-r"], capture_output=True, text=True, timeout=3,
        )
        diag["network"]["wifi_ssid"] = result.stdout.strip() if result.returncode == 0 else ""
        diag["network"]["wifi_connected"] = bool(diag["network"]["wifi_ssid"])
    except Exception:
        diag["network"]["wifi_connected"] = False
        diag["network"]["wifi_ssid"] = ""

    # Gateway reachability
    try:
        result = subprocess.run(
            ["ip", "route", "show", "default"],
            capture_output=True, text=True, timeout=3,
        )
        if result.returncode == 0 and result.stdout.strip():
            gateway = result.stdout.strip().split()[2]
            diag["network"]["gateway"] = gateway
            ping = subprocess.run(
                ["ping", "-c", "1", "-W", "2", gateway],
                capture_output=True, text=True, timeout=3,
            )
            diag["network"]["gateway_reachable"] = ping.returncode == 0
        else:
            diag["network"]["gateway"] = ""
            diag["network"]["gateway_reachable"] = False
    except Exception:
        diag["network"]["gateway"] = ""
        diag["network"]["gateway_reachable"] = False

    # Memory
    try:
        with open("/proc/meminfo", "r") as f:
            meminfo = f.read()
        mem = {}
        for line in meminfo.split("\n"):
            if ":" in line:
                key, val = line.split(":", 1)
                # Strip 'kB' and convert to int
                mem[key.strip()] = int(val.strip().split()[0]) if val.strip() else 0
        total = mem.get("MemTotal", 0)
        available = mem.get("MemAvailable", 0)
        diag["memory"] = {
            "total_mb": total // 1024,
            "available_mb": available // 1024,
            "used_percent": round((1 - available / total) * 100, 1) if total > 0 else 0,
        }
    except Exception:
        diag["memory"] = {"total_mb": 0, "available_mb": 0, "used_percent": 0}

    # Disk space
    diag["storage"] = {}
    for mount in ["/", "/var/log"]:
        try:
            result = subprocess.run(
                ["df", "-BM", mount],
                capture_output=True, text=True, timeout=5,
            )
            if result.returncode == 0:
                lines = result.stdout.strip().split("\n")
                if len(lines) >= 2:
                    parts = lines[1].split()
                    diag["storage"][mount] = {
                        "total_mb": int(parts[1].rstrip("M")),
                        "used_mb": int(parts[2].rstrip("M")),
                        "available_mb": int(parts[3].rstrip("M")),
                        "used_percent": parts[4],
                    }
        except Exception:
            pass

    # Temperature
    try:
        with open("/sys/class/thermal/thermal_zone0/temp", "r") as f:
            temp_raw = int(f.read().strip())
        diag["temperature_c"] = round(temp_raw / 1000.0, 1)
    except Exception:
        diag["temperature_c"] = None

    return diag


def register_routes(app: Flask) -> None:
    """Register all routes with the Flask application.

    Args:
        app: Flask application.
    """

    @app.route("/")
    def dashboard():
        """Render the main dashboard page."""
        cups_error = False
        error_message = ""
        try:
            client = get_cups_client(app)
            printers = get_all_printers(client, include_virtual=False)
            server_status = get_server_status()
            server_status["printers"] = [p.to_summary_dict() for p in printers]
        except CupsClientError as e:
            cups_error = True
            error_message = str(e)
            printers = []
            server_status = get_server_status()
            server_status["printers"] = []
            logger.warning(f"Dashboard: CUPS unavailable - {e}")

        return render_template(
            "dashboard.html",
            server_status=server_status,
            printers=printers,
            cups_error=cups_error,
            error_message=error_message,
        )

    @app.route("/queue")
    def queue():
        """Render the print queue page."""
        cups_error = False
        error_message = ""
        try:
            client = get_cups_client(app)
            jobs = get_all_jobs(client, which_jobs="all")
        except CupsClientError as e:
            cups_error = True
            error_message = str(e)
            jobs = []
            logger.warning(f"Queue: CUPS unavailable - {e}")

        return render_template(
            "queue.html",
            jobs=jobs,
            cups_error=cups_error,
            error_message=error_message,
        )

    @app.route("/settings")
    def settings():
        """Render the settings page."""
        server_info = get_server_status()
        return render_template("settings.html", server_info=server_info)

    @app.route("/diagnostics")
    def diagnostics():
        """Render the diagnostics page."""
        return render_template("diagnostics.html")

    @app.route("/api/status")
    def api_status():
        """Get server and printer status.

        Response matches api.yaml ServerStatus schema:
        - server: {status, uptime, hostname, ip_address}
        - printers: {total, online, offline}
        - jobs: {active, pending, completed_today}
        """
        server_info = _cached_call("server_status", get_server_status, 30)
        cups_error = False

        try:
            client = get_cups_client(app)
            printers = get_all_printers(client)
            jobs = get_all_jobs(client, which_jobs="all")
        except CupsClientError as e:
            cups_error = True
            printers = []
            jobs = []
            logger.warning(f"API status: CUPS unavailable - {e}")

        # Calculate printer stats
        online_printers = [p for p in printers if p.status in ("idle", "printing")]
        offline_printers = [p for p in printers if p.status in ("stopped", "offline")]

        # Calculate job stats
        active_jobs = [j for j in jobs if j.state in ("processing",)]
        pending_jobs = [j for j in jobs if j.state in ("pending", "pending-held")]

        status = {
            "server": {
                "status": "degraded" if cups_error else (
                    "running" if server_info["cups_running"] else "degraded"
                ),
                "uptime": server_info["uptime"],
                "hostname": server_info["hostname"],
                "ip_address": server_info["ip_address"],
                "cups_running": server_info["cups_running"],
                "avahi_running": server_info["avahi_running"],
                "wifi_connected": server_info["wifi_connected"],
                "wifi_ssid": server_info["wifi_ssid"],
                "cups_error": cups_error,
            },
            "printers": {
                "total": len(printers),
                "online": len(online_printers),
                "offline": len(offline_printers),
                "list": [p.to_summary_dict() for p in printers],
            },
            "jobs": {
                "active": len(active_jobs),
                "pending": len(pending_jobs),
                "total": len(jobs),
            },
        }
        return jsonify(status)

    @app.route("/api/printers")
    def api_printers():
        """Get list of all printers."""
        try:
            client = get_cups_client(app)
            printers = get_all_printers(client)
            return jsonify([p.to_dict() for p in printers])
        except CupsClientError as e:
            return jsonify({"error": str(e), "code": "CUPS_ERROR"}), 500

    @app.route("/api/printers/<name>")
    def api_printer_detail(name: str):
        """Get details for a specific printer."""
        try:
            client = get_cups_client(app)
            printer = get_printer(client, name)
            if printer:
                return jsonify(printer.to_dict())
            return jsonify({"error": "Printer not found", "code": "NOT_FOUND"}), 404
        except CupsClientError as e:
            return jsonify({"error": str(e), "code": "CUPS_ERROR"}), 500

    @app.route("/api/jobs")
    def api_jobs():
        """Get list of print jobs."""
        try:
            client = get_cups_client(app)

            # Get filter parameters
            status = request.args.get("status", "all")
            limit = min(int(request.args.get("limit", 50)), 100)

            # Map status filter
            if status == "pending":
                which_jobs = "not-completed"
            elif status == "completed":
                which_jobs = "completed"
            else:
                which_jobs = "all"

            jobs = get_all_jobs(client, which_jobs=which_jobs)
            jobs = jobs[:limit]

            return jsonify([j.to_dict() for j in jobs])
        except CupsClientError as e:
            return jsonify({"error": str(e), "code": "CUPS_ERROR"}), 500

    @app.route("/api/jobs/<int:job_id>")
    def api_job_detail(job_id: int):
        """Get details for a specific job."""
        try:
            client = get_cups_client(app)
            job = get_job(client, job_id)
            if job:
                return jsonify(job.to_dict())
            return jsonify({"error": "Job not found", "code": "NOT_FOUND"}), 404
        except CupsClientError as e:
            return jsonify({"error": str(e), "code": "CUPS_ERROR"}), 500

    @app.route("/api/jobs/<int:job_id>", methods=["DELETE"])
    def api_cancel_job(job_id: int):
        """Cancel a print job."""
        try:
            client = get_cups_client(app)
            job = get_job(client, job_id)

            if not job:
                return jsonify({"error": "Job not found", "code": "NOT_FOUND"}), 404

            if not job.can_cancel:
                return jsonify({
                    "error": "Job cannot be canceled",
                    "code": "INVALID_STATE"
                }), 400

            success = cancel_print_job(client, job_id)
            if success:
                return jsonify({
                    "success": True,
                    "message": f"Job {job_id} canceled"
                })
            return jsonify({
                "error": "Failed to cancel job",
                "code": "CANCEL_FAILED"
            }), 500
        except CupsClientError as e:
            return jsonify({"error": str(e), "code": "CUPS_ERROR"}), 500

    @app.route("/health")
    def health():
        """Health check endpoint with granular status."""
        if hasattr(app, "_ready") and not app._ready:
            return jsonify({
                "status": "starting",
                "timestamp": datetime.now().isoformat(),
            }), 503

        try:
            client = get_cups_client(app)
            printers = get_all_printers(client)
            return jsonify({
                "status": "healthy",
                "timestamp": datetime.now().isoformat(),
                "cups_connected": True,
                "printer_count": len(printers),
            })
        except CupsClientError:
            return jsonify({
                "status": "degraded",
                "timestamp": datetime.now().isoformat(),
                "cups_connected": False,
                "error": "Cannot connect to CUPS",
            }), 200  # 200, not 503: web service is up, CUPS is the issue

    @app.route("/api/diagnostics")
    def api_diagnostics():
        """Get comprehensive system diagnostics snapshot."""
        return jsonify(_cached_call("diagnostics", _get_system_diagnostics, 15))

    @app.route("/api/logs")
    def api_logs():
        """Get service logs from journald or in-memory ring buffer.

        Query params:
            service: printserver-web, cups, avahi-daemon, or app (default: printserver-web)
            lines: Number of lines to return (default: 100, max: 500)
        """
        service = request.args.get("service", "printserver-web")
        lines = min(int(request.args.get("lines", 100)), 500)

        if service not in ALLOWED_LOG_SERVICES:
            return jsonify({
                "error": f"Unknown service '{service}'",
                "code": "INVALID_SERVICE",
                "allowed": list(ALLOWED_LOG_SERVICES),
            }), 400

        # In-memory application logs
        if service == "app":
            if hasattr(app, "_log_buffer"):
                entries = list(app._log_buffer.get_entries(lines))
            else:
                entries = []
            return jsonify({"service": "app", "entries": entries})

        # CUPS error log (file-based, not journald)
        if service == "cups-error":
            try:
                result = subprocess.run(
                    ["tail", "-n", str(lines), "/var/log/cups/error_log"],
                    capture_output=True, text=True, timeout=5,
                )
                log_lines = (
                    result.stdout.strip().split("\n")
                    if result.stdout.strip() else []
                )
                return jsonify({"service": service, "entries": log_lines})
            except Exception as e:
                return jsonify({
                    "error": f"Could not read CUPS error log: {e}",
                    "code": "LOG_ERROR",
                }), 500

        # journald logs
        try:
            result = subprocess.run(
                ["journalctl", "-u", service, "-n", str(lines),
                 "--no-pager", "-o", "short-iso"],
                capture_output=True,
                text=True,
                timeout=10,
            )
            log_lines = result.stdout.strip().split("\n") if result.stdout.strip() else []
            return jsonify({
                "service": service,
                "entries": log_lines,
            })
        except Exception as e:
            logger.warning(f"Could not read logs for {service}: {e}")
            return jsonify({
                "error": f"Could not read logs: {e}",
                "code": "LOG_ERROR",
            }), 500

    @app.route("/api/printers/<name>/test-page", methods=["POST"])
    def api_print_test_page(name: str):
        """Print a CUPS test page on the specified printer."""
        try:
            client = get_cups_client(app)
            printer = get_printer(client, name)
            if not printer:
                return jsonify({"error": "Printer not found", "code": "NOT_FOUND"}), 404
            job_id = client.print_test_page(name)
            return jsonify({"success": True, "job_id": job_id, "printer": name})
        except CupsClientError as e:
            logger.error(f"Test page failed for '{name}': {e}")
            return jsonify({"error": str(e), "code": "CUPS_ERROR"}), 500

    @app.route("/api/system/services/<service>/restart", methods=["POST"])
    def api_restart_service(service: str):
        """Restart a system service via the restart helper script."""
        if service not in ALLOWED_RESTART_SERVICES:
            return jsonify({
                "error": f"Service '{service}' is not allowed",
                "code": "INVALID_SERVICE",
                "allowed": list(ALLOWED_RESTART_SERVICES),
            }), 400

        try:
            result = subprocess.run(
                ["sudo", RESTART_SCRIPT, service],
                capture_output=True, text=True, timeout=30,
            )
            if result.returncode == 0:
                logger.info(f"Service '{service}' restarted successfully")
                return jsonify({"success": True, "service": service})
            else:
                error_msg = result.stderr.strip() or f"Exit code {result.returncode}"
                logger.error(f"Failed to restart '{service}': {error_msg}")
                return jsonify({
                    "error": f"Failed to restart {service}: {error_msg}",
                    "code": "RESTART_FAILED",
                }), 500
        except Exception as e:
            logger.error(f"Service restart error for '{service}': {e}")
            return jsonify({
                "error": f"Could not restart service: {e}",
                "code": "RESTART_ERROR",
            }), 500

    @app.route("/api/diagnostics/export")
    def api_diagnostics_export():
        """Export complete diagnostics bundle as downloadable JSON."""
        bundle = {
            "export_timestamp": datetime.now().isoformat(),
            "system": _get_system_diagnostics(),
            "logs": {},
        }

        # Collect logs from all sources
        log_sources = {
            "printserver-web": ("journalctl", [
                "journalctl", "-u", "printserver-web", "-n", "200",
                "--no-pager", "-o", "short-iso",
            ]),
            "cups": ("journalctl", [
                "journalctl", "-u", "cups", "-n", "200",
                "--no-pager", "-o", "short-iso",
            ]),
            "avahi-daemon": ("journalctl", [
                "journalctl", "-u", "avahi-daemon", "-n", "200",
                "--no-pager", "-o", "short-iso",
            ]),
            "cups-error": ("file", [
                "tail", "-n", "200", "/var/log/cups/error_log",
            ]),
        }

        for source_name, (source_type, cmd) in log_sources.items():
            try:
                result = subprocess.run(
                    cmd, capture_output=True, text=True, timeout=10,
                )
                lines = (
                    result.stdout.strip().split("\n")
                    if result.stdout.strip() else []
                )
                bundle["logs"][source_name] = lines
            except Exception as e:
                bundle["logs"][source_name] = [f"Error reading logs: {e}"]

        # In-memory app logs
        if hasattr(app, "_log_buffer"):
            bundle["logs"]["app"] = list(app._log_buffer.get_entries(200))
        else:
            bundle["logs"]["app"] = []

        # CUPS printer info
        try:
            client = get_cups_client(app)
            printers = get_all_printers(client)
            bundle["printers"] = [p.to_dict() for p in printers]
        except CupsClientError:
            bundle["printers"] = []

        timestamp = datetime.now().strftime("%Y%m%d-%H%M%S")
        response = jsonify(bundle)
        response.headers["Content-Disposition"] = (
            f'attachment; filename="printserver-diagnostics-{timestamp}.json"'
        )
        return response

    @app.route("/api/system/hostname", methods=["GET"])
    def api_get_hostname():
        """Get current system hostname."""
        try:
            hostname = get_hostname()
            return jsonify({
                "hostname": hostname,
                "can_change": requires_root(),
            })
        except SystemUtilsError as e:
            return jsonify({"error": str(e), "code": "SYSTEM_ERROR"}), 500

    @app.route("/api/system/hostname", methods=["POST"])
    def api_set_hostname():
        """Set system hostname."""
        if not requires_root():
            return jsonify({
                "error": "Permission denied. Service must run as root to change hostname.",
                "code": "PERMISSION_DENIED",
            }), 403

        data = request.get_json()
        if not data or "hostname" not in data:
            return jsonify({
                "error": "Missing 'hostname' in request body",
                "code": "INVALID_REQUEST",
            }), 400

        new_hostname = data["hostname"].strip()

        is_valid, error_msg = validate_hostname(new_hostname)
        if not is_valid:
            return jsonify({
                "error": error_msg,
                "code": "INVALID_HOSTNAME",
            }), 400

        try:
            old_hostname = get_hostname()
            set_hostname(new_hostname)
            logger.info(f"Hostname changed from '{old_hostname}' to '{new_hostname}'")
            return jsonify({
                "success": True,
                "message": f"Hostname changed to '{new_hostname}'",
                "old_hostname": old_hostname,
                "new_hostname": new_hostname,
            })
        except SystemUtilsError as e:
            logger.error(f"Failed to set hostname: {e}")
            return jsonify({
                "error": str(e),
                "code": "SYSTEM_ERROR",
            }), 500

    @app.route("/api/system/hostname/validate", methods=["POST"])
    def api_validate_hostname():
        """Validate a hostname without setting it."""
        data = request.get_json()
        if not data or "hostname" not in data:
            return jsonify({
                "error": "Missing 'hostname' in request body",
                "code": "INVALID_REQUEST",
            }), 400

        hostname = data["hostname"].strip()
        is_valid, error_msg = validate_hostname(hostname)

        return jsonify({
            "valid": is_valid,
            "error": error_msg,
        })

    @app.route("/api/debug/jobs")
    def api_debug_jobs():
        """Debug endpoint to inspect raw CUPS job data."""
        try:
            client = get_cups_client(app)
            jobs_data = client.get_jobs(which_jobs="all")

            debug_data = {}
            for job_id, job_attrs in jobs_data.items():
                debug_data[str(job_id)] = {
                    "attributes": {
                        k: str(v) if not isinstance(v, (str, int, float, bool, type(None)))
                        else v
                        for k, v in job_attrs.items()
                    }
                }

            return jsonify({
                "total_jobs": len(jobs_data),
                "jobs": debug_data,
            })
        except CupsClientError as e:
            return jsonify({"error": str(e), "code": "CUPS_ERROR"}), 500

    @app.route("/api/debug/printers")
    def api_debug_printers():
        """Debug endpoint to inspect raw CUPS printer data."""
        try:
            client = get_cups_client(app)
            printers_data = client.get_printers()

            debug_data = {}
            for printer_name, printer_attrs in printers_data.items():
                debug_data[printer_name] = {
                    "attributes": {
                        k: str(v) if not isinstance(v, (str, int, float, bool, type(None)))
                        else v
                        for k, v in printer_attrs.items()
                    }
                }

            return jsonify({
                "total_printers": len(printers_data),
                "printers": debug_data,
            })
        except CupsClientError as e:
            return jsonify({"error": str(e), "code": "CUPS_ERROR"}), 500

    logger.info("Routes registered")
