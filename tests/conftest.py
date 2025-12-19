"""Pytest configuration and shared fixtures."""

import pytest
from unittest.mock import MagicMock


@pytest.fixture
def mock_cups_connection():
    """Create a mock CUPS connection for testing."""
    conn = MagicMock()
    conn.getPrinters.return_value = {
        "Brother_HL-L2350DW": {
            "printer-info": "Brother HL-L2350DW",
            "printer-location": "Office",
            "printer-make-and-model": "Brother HL-L2350DW",
            "printer-state": 3,  # idle
            "printer-state-message": "Ready",
            "printer-is-accepting-jobs": True,
            "printer-is-shared": True,
            "device-uri": "usb://Brother/HL-L2350DW",
        }
    }
    conn.getJobs.return_value = {
        1: {
            "job-name": "Test Document",
            "job-originating-user-name": "user",
            "job-state": 3,  # pending
            "job-k-octets": 100,
            "job-printer-uri": "ipp://localhost/printers/Brother_HL-L2350DW",
            "time-at-creation": 1702900000,
        }
    }
    return conn


@pytest.fixture
def sample_printer_data():
    """Sample printer data for testing."""
    return {
        "name": "Brother_HL-L2350DW",
        "uri": "usb://Brother/HL-L2350DW",
        "status": "idle",
        "status_message": "Ready",
        "is_accepting_jobs": True,
        "is_shared": True,
        "make_model": "Brother HL-L2350DW",
        "location": "Office",
        "info": "Brother HL-L2350DW",
    }


@pytest.fixture
def sample_job_data():
    """Sample print job data for testing."""
    return {
        "id": 1,
        "title": "Test Document",
        "user": "testuser",
        "state": "pending",
        "state_message": "Waiting in queue",
        "size": 102400,
        "pages": 5,
        "pages_completed": 0,
        "created_at": "2024-12-18T10:00:00",
        "completed_at": None,
        "printer_name": "Brother_HL-L2350DW",
    }
