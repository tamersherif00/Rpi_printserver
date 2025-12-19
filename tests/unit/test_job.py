"""Tests for PrintJob model."""

from datetime import datetime
from unittest.mock import MagicMock

import pytest

from printserver.job import (
    PrintJob,
    get_all_jobs,
    get_job,
    cancel_job,
    get_pending_jobs,
    get_job_count,
)


class TestPrintJob:
    """Tests for PrintJob dataclass."""

    def test_from_cups_data(self):
        """Test creating PrintJob from CUPS data."""
        cups_data = {
            "job-name": "Test Document.pdf",
            "job-originating-user-name": "testuser",
            "job-state": 3,  # pending
            "job-state-message": "Waiting",
            "job-k-octets": 100,
            "job-media-sheets": 5,
            "job-media-sheets-completed": 0,
            "job-printer-uri": "ipp://localhost/printers/Brother",
            "time-at-creation": 1702900000,
        }

        job = PrintJob.from_cups_data(1, cups_data)

        assert job.id == 1
        assert job.title == "Test Document.pdf"
        assert job.user == "testuser"
        assert job.state == "pending"
        assert job.size == 100 * 1024
        assert job.pages == 5
        assert job.pages_completed == 0
        assert job.printer_name == "Brother"
        assert job.created_at is not None

    def test_from_cups_data_minimal(self):
        """Test creating PrintJob with minimal data."""
        cups_data = {}

        job = PrintJob.from_cups_data(1, cups_data)

        assert job.id == 1
        assert job.title == "Untitled"
        assert job.user == "unknown"
        assert job.state == "unknown"
        assert job.size == 0
        assert job.pages is None

    def test_to_dict(self, sample_job_data):
        """Test converting PrintJob to dictionary."""
        job = PrintJob(
            id=1,
            title="Test",
            user="user",
            state="pending",
            state_message="Waiting",
            size=1024,
            pages=5,
            pages_completed=0,
            created_at=datetime(2024, 12, 18, 10, 0, 0),
            completed_at=None,
            printer_name="Brother",
        )

        result = job.to_dict()

        assert result["id"] == 1
        assert result["title"] == "Test"
        assert result["user"] == "user"
        assert result["state"] == "pending"
        assert result["created_at"] == "2024-12-18T10:00:00"
        assert result["completed_at"] is None

    def test_is_pending_true(self):
        """Test is_pending for pending job."""
        job = PrintJob(
            id=1, title="Test", user="user", state="pending",
            state_message="", size=0, pages=None, pages_completed=0,
            created_at=None, completed_at=None, printer_name="Brother"
        )
        assert job.is_pending is True

    def test_is_pending_held(self):
        """Test is_pending for held job."""
        job = PrintJob(
            id=1, title="Test", user="user", state="pending-held",
            state_message="", size=0, pages=None, pages_completed=0,
            created_at=None, completed_at=None, printer_name="Brother"
        )
        assert job.is_pending is True

    def test_is_pending_false(self):
        """Test is_pending for processing job."""
        job = PrintJob(
            id=1, title="Test", user="user", state="processing",
            state_message="", size=0, pages=None, pages_completed=0,
            created_at=None, completed_at=None, printer_name="Brother"
        )
        assert job.is_pending is False

    def test_is_active_processing(self):
        """Test is_active for processing job."""
        job = PrintJob(
            id=1, title="Test", user="user", state="processing",
            state_message="", size=0, pages=None, pages_completed=0,
            created_at=None, completed_at=None, printer_name="Brother"
        )
        assert job.is_active is True

    def test_is_active_false(self):
        """Test is_active for completed job."""
        job = PrintJob(
            id=1, title="Test", user="user", state="completed",
            state_message="", size=0, pages=None, pages_completed=0,
            created_at=None, completed_at=None, printer_name="Brother"
        )
        assert job.is_active is False

    def test_is_complete_completed(self):
        """Test is_complete for completed job."""
        job = PrintJob(
            id=1, title="Test", user="user", state="completed",
            state_message="", size=0, pages=None, pages_completed=0,
            created_at=None, completed_at=None, printer_name="Brother"
        )
        assert job.is_complete is True

    def test_is_complete_canceled(self):
        """Test is_complete for canceled job."""
        job = PrintJob(
            id=1, title="Test", user="user", state="canceled",
            state_message="", size=0, pages=None, pages_completed=0,
            created_at=None, completed_at=None, printer_name="Brother"
        )
        assert job.is_complete is True

    def test_is_complete_false(self):
        """Test is_complete for pending job."""
        job = PrintJob(
            id=1, title="Test", user="user", state="pending",
            state_message="", size=0, pages=None, pages_completed=0,
            created_at=None, completed_at=None, printer_name="Brother"
        )
        assert job.is_complete is False

    def test_can_cancel_true(self):
        """Test can_cancel for pending job."""
        job = PrintJob(
            id=1, title="Test", user="user", state="pending",
            state_message="", size=0, pages=None, pages_completed=0,
            created_at=None, completed_at=None, printer_name="Brother"
        )
        assert job.can_cancel is True

    def test_can_cancel_false(self):
        """Test can_cancel for completed job."""
        job = PrintJob(
            id=1, title="Test", user="user", state="completed",
            state_message="", size=0, pages=None, pages_completed=0,
            created_at=None, completed_at=None, printer_name="Brother"
        )
        assert job.can_cancel is False


class TestJobFunctions:
    """Tests for job helper functions."""

    def test_get_all_jobs(self):
        """Test getting all jobs."""
        mock_client = MagicMock()
        mock_client.get_jobs.return_value = {
            1: {"job-name": "Doc1", "job-state": 3, "time-at-creation": 1702900000},
            2: {"job-name": "Doc2", "job-state": 9, "time-at-creation": 1702900100},
        }

        jobs = get_all_jobs(mock_client)

        assert len(jobs) == 2

    def test_get_all_jobs_empty(self):
        """Test getting jobs when queue is empty."""
        mock_client = MagicMock()
        mock_client.get_jobs.return_value = {}

        jobs = get_all_jobs(mock_client)

        assert len(jobs) == 0

    def test_get_job_found(self):
        """Test getting a specific job."""
        mock_client = MagicMock()
        mock_client.get_job_attributes.return_value = {
            "job-name": "Test",
            "job-state": 3,
        }

        job = get_job(mock_client, 1)

        assert job is not None
        assert job.id == 1

    def test_get_job_not_found(self):
        """Test getting a job that doesn't exist."""
        mock_client = MagicMock()
        mock_client.get_job_attributes.side_effect = Exception("Not found")

        job = get_job(mock_client, 999)

        assert job is None

    def test_cancel_job_success(self):
        """Test canceling a job successfully."""
        mock_client = MagicMock()
        mock_client.get_job_attributes.return_value = {
            "job-name": "Test",
            "job-state": 3,  # pending - can cancel
        }
        mock_client.cancel_job.return_value = True

        result = cancel_job(mock_client, 1)

        assert result is True

    def test_cancel_job_completed(self):
        """Test canceling a completed job fails."""
        mock_client = MagicMock()
        mock_client.get_job_attributes.return_value = {
            "job-name": "Test",
            "job-state": 9,  # completed - can't cancel
        }

        result = cancel_job(mock_client, 1)

        assert result is False

    def test_get_pending_jobs(self):
        """Test getting pending jobs."""
        mock_client = MagicMock()
        mock_client.get_jobs.return_value = {
            1: {"job-name": "Doc1", "job-state": 3},
        }

        jobs = get_pending_jobs(mock_client)

        assert len(jobs) >= 0
        mock_client.get_jobs.assert_called_with(which_jobs="not-completed")

    def test_get_job_count(self):
        """Test getting job count."""
        mock_client = MagicMock()
        mock_client.get_jobs.return_value = {
            1: {"job-name": "Doc1", "job-state": 3},
            2: {"job-name": "Doc2", "job-state": 3},
        }

        count = get_job_count(mock_client)

        assert count == 2
