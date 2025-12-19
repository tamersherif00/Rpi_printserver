"""Contract tests for web API endpoints.

These tests verify the API endpoints match the OpenAPI specification
defined in specs/001-wifi-print-server/contracts/api.yaml
"""

import json
from datetime import datetime
from unittest.mock import MagicMock, patch

import pytest


@pytest.fixture
def app():
    """Create test Flask application."""
    from web.app import create_app

    app = create_app({"TESTING": True})
    return app


@pytest.fixture
def client(app):
    """Create test client."""
    return app.test_client()


@pytest.fixture
def mock_cups():
    """Mock CUPS connection for testing."""
    with patch("printserver.cups_client.cups") as mock:
        mock_conn = MagicMock()
        mock.Connection.return_value = mock_conn
        yield mock_conn


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
        assert data["status"] in ["healthy", "unhealthy", "degraded"]


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
