"""Tests for CUPS client wrapper."""

from unittest.mock import MagicMock, patch

import pytest

from printserver.cups_client import (
    CupsClient,
    CupsClientError,
    get_printer_state_string,
    get_job_state_string,
    PRINTER_STATE_IDLE,
    PRINTER_STATE_PROCESSING,
    PRINTER_STATE_STOPPED,
    JOB_STATE_PENDING,
    JOB_STATE_PROCESSING,
    JOB_STATE_COMPLETED,
    JOB_STATE_CANCELED,
)


class TestCupsClient:
    """Tests for CupsClient class."""

    def test_init(self):
        """Test client initialization."""
        client = CupsClient(host="test-host", port=6310)
        assert client.host == "test-host"
        assert client.port == 6310
        assert client._connection is None

    def test_is_connected_false_initially(self):
        """Test is_connected is False before connecting."""
        client = CupsClient()
        assert client.is_connected is False

    def test_disconnect(self):
        """Test disconnect clears connection."""
        client = CupsClient()
        client._connection = MagicMock()
        client.disconnect()
        assert client._connection is None
        assert client.is_connected is False

    def test_connection_property_raises_when_not_connected(self):
        """Test connection property raises when not connected."""
        client = CupsClient()
        with pytest.raises(CupsClientError) as exc_info:
            _ = client.connection
        assert "Not connected" in str(exc_info.value)

    @patch("printserver.cups_client.cups")
    def test_connect_success(self, mock_cups):
        """Test successful connection to CUPS."""
        mock_conn = MagicMock()
        mock_cups.Connection.return_value = mock_conn

        client = CupsClient()
        client.connect()

        assert client.is_connected
        mock_cups.Connection.assert_called_once()

    @patch("printserver.cups_client.cups")
    def test_connect_failure(self, mock_cups):
        """Test connection failure handling."""
        mock_cups.Connection.side_effect = Exception("Connection refused")

        client = CupsClient()
        with pytest.raises(CupsClientError) as exc_info:
            client.connect()

        assert "Failed to connect" in str(exc_info.value)

    def test_get_printers(self, mock_cups_connection):
        """Test getting printers."""
        client = CupsClient()
        client._connection = mock_cups_connection

        printers = client.get_printers()

        assert "Brother_HL-L2350DW" in printers
        mock_cups_connection.getPrinters.assert_called_once()

    def test_get_printers_error(self):
        """Test get_printers error handling."""
        client = CupsClient()
        mock_conn = MagicMock()
        mock_conn.getPrinters.side_effect = Exception("CUPS error")
        client._connection = mock_conn

        with pytest.raises(CupsClientError):
            client.get_printers()

    def test_get_jobs(self, mock_cups_connection):
        """Test getting print jobs."""
        client = CupsClient()
        client._connection = mock_cups_connection

        jobs = client.get_jobs()

        assert 1 in jobs
        mock_cups_connection.getJobs.assert_called_once()

    def test_cancel_job(self, mock_cups_connection):
        """Test canceling a job."""
        client = CupsClient()
        client._connection = mock_cups_connection

        result = client.cancel_job(1)

        assert result is True
        mock_cups_connection.cancelJob.assert_called_once_with(1)

    def test_cancel_job_error(self):
        """Test cancel job error handling."""
        client = CupsClient()
        mock_conn = MagicMock()
        mock_conn.cancelJob.side_effect = Exception("Job not found")
        client._connection = mock_conn

        with pytest.raises(CupsClientError):
            client.cancel_job(999)

    def test_get_default_printer(self, mock_cups_connection):
        """Test getting default printer."""
        mock_cups_connection.getDefault.return_value = "Brother_HL-L2350DW"
        client = CupsClient()
        client._connection = mock_cups_connection

        default = client.get_default_printer()

        assert default == "Brother_HL-L2350DW"


class TestStateFunctions:
    """Tests for state conversion functions."""

    def test_get_printer_state_string_idle(self):
        """Test printer idle state."""
        assert get_printer_state_string(PRINTER_STATE_IDLE) == "idle"

    def test_get_printer_state_string_processing(self):
        """Test printer processing state."""
        assert get_printer_state_string(PRINTER_STATE_PROCESSING) == "printing"

    def test_get_printer_state_string_stopped(self):
        """Test printer stopped state."""
        assert get_printer_state_string(PRINTER_STATE_STOPPED) == "stopped"

    def test_get_printer_state_string_unknown(self):
        """Test unknown printer state."""
        assert get_printer_state_string(999) == "offline"

    def test_get_job_state_string_pending(self):
        """Test job pending state."""
        assert get_job_state_string(JOB_STATE_PENDING) == "pending"

    def test_get_job_state_string_processing(self):
        """Test job processing state."""
        assert get_job_state_string(JOB_STATE_PROCESSING) == "processing"

    def test_get_job_state_string_completed(self):
        """Test job completed state."""
        assert get_job_state_string(JOB_STATE_COMPLETED) == "completed"

    def test_get_job_state_string_canceled(self):
        """Test job canceled state."""
        assert get_job_state_string(JOB_STATE_CANCELED) == "canceled"

    def test_get_job_state_string_unknown(self):
        """Test unknown job state."""
        assert get_job_state_string(999) == "unknown"
