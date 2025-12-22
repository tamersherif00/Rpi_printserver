"""Flask routes for the print server web interface."""

import logging
import socket
import subprocess
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


def get_cups_client(app: Flask) -> CupsClient:
    """Get a connected CUPS client.

    Args:
        app: Flask application.

    Returns:
        Connected CupsClient instance.
    """
    client = CupsClient(
        host=app.config.get("CUPS_HOST", "localhost"),
        port=app.config.get("CUPS_PORT", 631),
    )
    client.connect()
    return client


def get_server_status() -> dict[str, Any]:
    """Get overall server status information.

    Returns:
        Dictionary with server status.
    """
    # Get hostname
    hostname = socket.gethostname()

    # Get IP address
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("8.8.8.8", 80))
        ip_address = s.getsockname()[0]
        s.close()
    except Exception:
        ip_address = "127.0.0.1"

    # Get uptime
    try:
        with open("/proc/uptime", "r") as f:
            uptime = int(float(f.read().split()[0]))
    except Exception:
        uptime = 0

    # Check if CUPS is running
    try:
        result = subprocess.run(
            ["systemctl", "is-active", "cups"],
            capture_output=True,
            text=True,
            timeout=5,
        )
        cups_running = result.stdout.strip() == "active"
    except Exception:
        cups_running = True  # Assume running if we can't check

    # Check if Avahi is running
    try:
        result = subprocess.run(
            ["systemctl", "is-active", "avahi-daemon"],
            capture_output=True,
            text=True,
            timeout=5,
        )
        avahi_running = result.stdout.strip() == "active"
    except Exception:
        avahi_running = True  # Assume running if we can't check

    # Get WiFi status
    wifi_connected = False
    wifi_ssid = ""
    wifi_signal = 0

    try:
        result = subprocess.run(
            ["iwgetid", "-r"],
            capture_output=True,
            text=True,
            timeout=5,
        )
        if result.returncode == 0:
            wifi_ssid = result.stdout.strip()
            wifi_connected = bool(wifi_ssid)

        # Get signal strength
        result = subprocess.run(
            ["iwconfig", "wlan0"],
            capture_output=True,
            text=True,
            timeout=5,
        )
        if "Signal level" in result.stdout:
            # Parse signal level (varies by driver)
            for line in result.stdout.split("\n"):
                if "Signal level" in line:
                    # Try to extract percentage or dBm
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


def register_routes(app: Flask) -> None:
    """Register all routes with the Flask application.

    Args:
        app: Flask application.
    """

    @app.route("/")
    def dashboard():
        """Render the main dashboard page."""
        try:
            client = get_cups_client(app)
            printers = get_all_printers(client)
            server_status = get_server_status()
            server_status["printers"] = [p.to_summary_dict() for p in printers]
        except CupsClientError:
            printers = []
            server_status = get_server_status()
            server_status["printers"] = []

        return render_template(
            "dashboard.html",
            server_status=server_status,
            printers=printers,
        )

    @app.route("/queue")
    def queue():
        """Render the print queue page."""
        try:
            client = get_cups_client(app)
            jobs = get_all_jobs(client, which_jobs="all")
        except CupsClientError:
            jobs = []

        return render_template("queue.html", jobs=jobs)

    @app.route("/settings")
    def settings():
        """Render the settings page."""
        server_info = get_server_status()
        return render_template("settings.html", server_info=server_info)

    @app.route("/api/status")
    def api_status():
        """Get server and printer status.

        Response matches api.yaml ServerStatus schema:
        - server: {status, uptime, hostname, ip_address}
        - printers: {total, online, offline}
        - jobs: {active, pending, completed_today}
        """
        try:
            client = get_cups_client(app)
            printers = get_all_printers(client)
            jobs = get_all_jobs(client, which_jobs="all")
            server_info = get_server_status()

            # Calculate printer stats
            online_printers = [p for p in printers if p.status in ("idle", "printing")]
            offline_printers = [p for p in printers if p.status in ("stopped", "offline")]

            # Calculate job stats
            active_jobs = [j for j in jobs if j.state in ("processing",)]
            pending_jobs = [j for j in jobs if j.state in ("pending", "pending-held")]

            status = {
                "server": {
                    "status": "running" if server_info["cups_running"] else "degraded",
                    "uptime": server_info["uptime"],
                    "hostname": server_info["hostname"],
                    "ip_address": server_info["ip_address"],
                    "cups_running": server_info["cups_running"],
                    "avahi_running": server_info["avahi_running"],
                    "wifi_connected": server_info["wifi_connected"],
                    "wifi_ssid": server_info["wifi_ssid"],
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
        except CupsClientError as e:
            return jsonify({"error": str(e), "code": "CUPS_ERROR"}), 500

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

            # Apply limit
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
        """Health check endpoint."""
        try:
            client = get_cups_client(app)
            printers = get_all_printers(client)
            return jsonify({
                "status": "healthy",
                "timestamp": datetime.now().isoformat(),
                "printer_count": len(printers),
            })
        except CupsClientError:
            return jsonify({
                "status": "unhealthy",
                "timestamp": datetime.now().isoformat(),
                "error": "Cannot connect to CUPS",
            }), 503

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
        """Set system hostname.

        Request body:
            {
                "hostname": "new-hostname"
            }
        """
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

        # Validate hostname
        is_valid, error_msg = validate_hostname(new_hostname)
        if not is_valid:
            return jsonify({
                "error": error_msg,
                "code": "INVALID_HOSTNAME",
            }), 400

        # Set hostname
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
        """Validate a hostname without setting it.

        Request body:
            {
                "hostname": "hostname-to-validate"
            }
        """
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
        """Debug endpoint to inspect raw CUPS job data.

        This endpoint returns raw CUPS job attributes for debugging purposes.
        """
        try:
            client = get_cups_client(app)
            jobs_data = client.get_jobs(which_jobs="all")

            # Convert to JSON-serializable format
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

    logger.info("Routes registered")
