"""Contract tests for web API endpoints.

These tests verify the API endpoints match the OpenAPI specification
defined in specs/001-wifi-print-server/contracts/api.yaml
"""

import json
import sys
from datetime import datetime
from unittest.mock import MagicMock, patch

import pytest


@pytest.fixture
def mock_cups():
    """Mock CUPS connection for testing.

    Uses sys.modules patching because cups is imported locally
    inside CupsClient methods (``import cups``).

    Must be activated before the app fixture so the before_request
    startup hook connects to the mock.
    """
    mock_mod = MagicMock()
    mock_conn = MagicMock()
    mock_mod.Connection.return_value = mock_conn
    with patch.dict(sys.modules, {"cups": mock_mod}):
        yield mock_conn


@pytest.fixture
def app(mock_cups):
    """Create test Flask application.

    Depends on mock_cups so the CUPS module is mocked before
    the before_request startup hook fires on the first request.
    """
    from web.app import create_app

    app = create_app({"TESTING": True})
    return app


@pytest.fixture
def client(app):
    """Create test client."""
    return app.test_client()


class TestStatusEndpoint:
    """Contract tests for GET /api/status."""

    def test_status_returns_200(self, client, mock_cups):
        """Test status endpoint returns 200 OK."""
        mock_cups.getPrinters.return_value = {}
        mock_cups.getJobs.return_value = {}

        response = client.get("/api/status")

        assert response.status_code == 200

    def test_status_returns_json(self, client, mock_cups):
        """Test status endpoint returns JSON."""
        mock_cups.getPrinters.return_value = {}
        mock_cups.getJobs.return_value = {}

        response = client.get("/api/status")

        assert response.content_type == "application/json"

    def test_status_schema(self, client, mock_cups):
        """Test status response matches schema."""
        mock_cups.getPrinters.return_value = {"TestPrinter": {}}
        mock_cups.getJobs.return_value = {}

        response = client.get("/api/status")
        data = json.loads(response.data)

        # Required fields per api.yaml
        assert "server" in data
        assert "status" in data["server"]
        assert "uptime" in data["server"]

        assert "printers" in data
        assert "total" in data["printers"]
        assert "online" in data["printers"]

        assert "jobs" in data
        assert "active" in data["jobs"]
        assert "pending" in data["jobs"]


class TestPrintersEndpoint:
    """Contract tests for GET /api/printers."""

    def test_printers_returns_200(self, client, mock_cups):
        """Test printers endpoint returns 200 OK."""
        mock_cups.getPrinters.return_value = {}

        response = client.get("/api/printers")

        assert response.status_code == 200

    def test_printers_returns_list(self, client, mock_cups):
        """Test printers endpoint returns a list."""
        mock_cups.getPrinters.return_value = {}

        response = client.get("/api/printers")
        data = json.loads(response.data)

        assert isinstance(data, list)

    def test_printers_schema(self, client, mock_cups):
        """Test printer objects match schema."""
        mock_cups.getPrinters.return_value = {
            "Brother": {
                "device-uri": "usb://Brother/HL-L2350DW",
                "printer-state": 3,
                "printer-state-message": "Ready",
                "printer-is-accepting-jobs": True,
                "printer-info": "Brother HL-L2350DW",
                "printer-location": "Office",
            }
        }

        response = client.get("/api/printers")
        data = json.loads(response.data)

        assert len(data) == 1
        printer = data[0]

        # Required fields per api.yaml
        assert "name" in printer
        assert "status" in printer
        assert "uri" in printer


class TestPrinterDetailEndpoint:
    """Contract tests for GET /api/printers/{name}."""

    def test_printer_detail_returns_200(self, client, mock_cups):
        """Test printer detail returns 200 for existing printer."""
        mock_cups.getPrinters.return_value = {
            "Brother": {
                "device-uri": "usb://Brother/HL-L2350DW",
                "printer-state": 3,
            }
        }

        response = client.get("/api/printers/Brother")

        assert response.status_code == 200

    def test_printer_detail_returns_404(self, client, mock_cups):
        """Test printer detail returns 404 for non-existent printer."""
        mock_cups.getPrinters.return_value = {}

        response = client.get("/api/printers/NonExistent")

        assert response.status_code == 404


class TestJobsEndpoint:
    """Contract tests for GET /api/jobs."""

    def test_jobs_returns_200(self, client, mock_cups):
        """Test jobs endpoint returns 200 OK."""
        mock_cups.getJobs.return_value = {}

        response = client.get("/api/jobs")

        assert response.status_code == 200

    def test_jobs_returns_list(self, client, mock_cups):
        """Test jobs endpoint returns a list."""
        mock_cups.getJobs.return_value = {}

        response = client.get("/api/jobs")
        data = json.loads(response.data)

        assert isinstance(data, list)

    def test_jobs_schema(self, client, mock_cups):
        """Test job objects match schema."""
        mock_cups.getJobs.return_value = {
            1: {
                "job-name": "test.pdf",
                "job-originating-user-name": "testuser",
                "job-state": 3,
                "job-state-message": "Pending",
                "time-at-creation": 1702900000,
            }
        }

        response = client.get("/api/jobs")
        data = json.loads(response.data)

        assert len(data) == 1
        job = data[0]

        # Required fields per api.yaml
        assert "id" in job
        assert "title" in job
        assert "state" in job

    def test_jobs_filter_by_state(self, client, mock_cups):
        """Test filtering jobs by state."""
        mock_cups.getJobs.return_value = {}

        response = client.get("/api/jobs?state=pending")

        assert response.status_code == 200
        mock_cups.getJobs.assert_called()

    def test_jobs_filter_by_printer(self, client, mock_cups):
        """Test filtering jobs by printer."""
        mock_cups.getJobs.return_value = {}

        response = client.get("/api/jobs?printer=Brother")

        assert response.status_code == 200


class TestJobDetailEndpoint:
    """Contract tests for GET /api/jobs/{id}."""

    def test_job_detail_returns_200(self, client, mock_cups):
        """Test job detail returns 200 for existing job."""
        mock_cups.getJobAttributes.return_value = {
            "job-name": "test.pdf",
            "job-state": 3,
        }

        response = client.get("/api/jobs/1")

        assert response.status_code == 200

    def test_job_detail_returns_404(self, client, mock_cups):
        """Test job detail returns 404 for non-existent job."""
        mock_cups.getJobAttributes.side_effect = Exception("Not found")

        response = client.get("/api/jobs/999")

        assert response.status_code == 404


class TestCancelJobEndpoint:
    """Contract tests for DELETE /api/jobs/{id}."""

    def test_cancel_job_returns_200(self, client, mock_cups):
        """Test cancel job returns 200 on success."""
        mock_cups.getJobAttributes.return_value = {
            "job-name": "test.pdf",
            "job-state": 3,  # pending
        }
        mock_cups.cancelJob.return_value = None

        response = client.delete("/api/jobs/1")

        assert response.status_code == 200

    def test_cancel_job_returns_404(self, client, mock_cups):
        """Test cancel job returns 404 for non-existent job."""
        mock_cups.getJobAttributes.side_effect = Exception("Not found")

        response = client.delete("/api/jobs/999")

        assert response.status_code == 404

    def test_cancel_job_returns_400_for_completed(self, client, mock_cups):
        """Test cancel job returns 400 for completed job."""
        mock_cups.getJobAttributes.return_value = {
            "job-name": "test.pdf",
            "job-state": 9,  # completed
        }

        response = client.delete("/api/jobs/1")

        assert response.status_code == 400


class TestHealthEndpoint:
    """Contract tests for GET /health."""

    def test_health_returns_200(self, client, mock_cups):
        """Test health endpoint returns 200 OK."""
        mock_cups.getPrinters.return_value = {}

        response = client.get("/health")

        assert response.status_code == 200

    def test_health_returns_json(self, client, mock_cups):
        """Test health endpoint returns JSON."""
        mock_cups.getPrinters.return_value = {}

        response = client.get("/health")

        assert response.content_type == "application/json"

    def test_health_schema(self, client, mock_cups):
        """Test health response includes required fields."""
        mock_cups.getPrinters.return_value = {}

        response = client.get("/health")
        data = json.loads(response.data)

        assert "status" in data
        assert data["status"] in ["healthy", "degraded", "starting"]


class TestPageRoutes:
    """Tests for HTML page routes."""

    def test_dashboard_returns_200(self, client, mock_cups):
        """Test dashboard page returns 200."""
        mock_cups.getPrinters.return_value = {}
        mock_cups.getJobs.return_value = {}

        response = client.get("/")

        assert response.status_code == 200
        assert b"<!DOCTYPE html>" in response.data or b"<html" in response.data

    def test_queue_returns_200(self, client, mock_cups):
        """Test queue page returns 200."""
        mock_cups.getJobs.return_value = {}

        response = client.get("/queue")

        assert response.status_code == 200
        assert b"<!DOCTYPE html>" in response.data or b"<html" in response.data

    def test_diagnostics_returns_200(self, client, mock_cups):
        """Test diagnostics page returns 200."""
        response = client.get("/diagnostics")

        assert response.status_code == 200
        assert b"Diagnostics" in response.data


class TestPrintTestPageEndpoint:
    """Contract tests for POST /api/printers/{name}/test-page."""

    def test_print_test_page_success(self, client, mock_cups):
        """Test printing a test page returns 200."""
        mock_cups.getPrinters.return_value = {
            "Brother": {
                "device-uri": "usb://Brother/HL-L2350DW",
                "printer-state": 3,
                "printer-state-message": "Ready",
                "printer-is-accepting-jobs": True,
            }
        }
        mock_cups.printTestPage.return_value = 42

        response = client.post("/api/printers/Brother/test-page")

        assert response.status_code == 200
        data = json.loads(response.data)
        assert data["success"] is True
        assert data["job_id"] == 42

    def test_print_test_page_printer_not_found(self, client, mock_cups):
        """Test print test page returns 404 for unknown printer."""
        mock_cups.getPrinters.return_value = {}

        response = client.post("/api/printers/NonExistent/test-page")

        assert response.status_code == 404


class TestServiceRestartEndpoint:
    """Contract tests for POST /api/system/services/{service}/restart."""

    def test_restart_invalid_service(self, client, mock_cups):
        """Test restart returns 400 for non-whitelisted service."""
        response = client.post("/api/system/services/nginx/restart")

        assert response.status_code == 400
        data = json.loads(response.data)
        assert data["code"] == "INVALID_SERVICE"

    @patch("web.routes.subprocess.run")
    def test_restart_success(self, mock_run, client, mock_cups):
        """Test restart returns 200 on success."""
        mock_run.return_value = MagicMock(returncode=0, stderr="")

        response = client.post("/api/system/services/cups/restart")

        assert response.status_code == 200
        data = json.loads(response.data)
        assert data["success"] is True

    @patch("web.routes.subprocess.run")
    def test_restart_failure(self, mock_run, client, mock_cups):
        """Test restart returns 500 on failure."""
        mock_run.return_value = MagicMock(returncode=1, stderr="Permission denied")

        response = client.post("/api/system/services/cups/restart")

        assert response.status_code == 500


class TestDiagnosticsExportEndpoint:
    """Contract tests for GET /api/diagnostics/export."""

    @patch("web.routes.subprocess.run")
    def test_export_returns_json(self, mock_run, client, mock_cups):
        """Test export returns downloadable JSON."""
        mock_run.return_value = MagicMock(
            returncode=0, stdout="", stderr=""
        )
        mock_cups.getPrinters.return_value = {}

        response = client.get("/api/diagnostics/export")

        assert response.status_code == 200
        assert response.content_type == "application/json"
        assert "attachment" in response.headers.get("Content-Disposition", "")

        data = json.loads(response.data)
        assert "system" in data
        assert "logs" in data
        assert "export_timestamp" in data


class TestLogsEndpoint:
    """Contract tests for GET /api/logs."""

    def test_logs_invalid_service(self, client, mock_cups):
        """Test logs returns 400 for invalid service."""
        response = client.get("/api/logs?service=invalid")

        assert response.status_code == 400

    def test_logs_app_returns_entries(self, client, mock_cups):
        """Test in-memory app logs return entries."""
        response = client.get("/api/logs?service=app")

        assert response.status_code == 200
        data = json.loads(response.data)
        assert data["service"] == "app"
        assert "entries" in data

    def test_logs_cups_error_accepted(self, client, mock_cups):
        """Test cups-error is an accepted log service."""
        # Will fail to read the file on non-Pi, but won't return 400
        response = client.get("/api/logs?service=cups-error")

        # Either 200 (file found) or 500 (file not found) - not 400
        assert response.status_code != 400
