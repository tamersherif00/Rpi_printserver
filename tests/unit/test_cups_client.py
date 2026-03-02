"""Tests for CUPS client wrapper."""

import sys
import time
from unittest.mock import MagicMock, patch

import pytest

from printserver.cups_client import (
    CupsClient,
    CupsClientError,
    MAX_CONNECTION_AGE,
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


@pytest.fixture
def mock_cups_module():
    """Mock the cups module for local import inside connect methods."""
    mock_mod = MagicMock()
    with patch.dict(sys.modules, {"cups": mock_mod}):
        yield mock_mod


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
        client._connected_at = time.monotonic()
        client.disconnect()
        assert client._connection is None
        assert client.is_connected is False
        assert client._connected_at == 0.0

    def test_connection_property_raises_when_not_connected(self):
        """Test connection property raises when not connected."""
        client = CupsClient()
        with pytest.raises(CupsClientError) as exc_info:
            _ = client.connection
        assert "Not connected" in str(exc_info.value)

    def test_connect_success(self, mock_cups_module):
        """Test successful connection to CUPS."""
        mock_conn = MagicMock()
        mock_cups_module.Connection.return_value = mock_conn

        client = CupsClient()
        client.connect()

        assert client.is_connected
        assert client._connected_at > 0
        mock_cups_module.Connection.assert_called_once()

    def test_connect_failure(self, mock_cups_module):
        """Test connection failure handling."""
        mock_cups_module.Connection.side_effect = Exception("Connection refused")

        client = CupsClient()
        with pytest.raises(CupsClientError) as exc_info:
            client.connect()

        assert "Failed to connect" in str(exc_info.value)

    def test_get_printers(self, mock_cups_connection):
        """Test getting printers."""
        client = CupsClient()
        client._connection = mock_cups_connection
        client._connected_at = time.monotonic()
        mock_cups_connection.getServer.return_value = "localhost"

        printers = client.get_printers()

        assert "Brother_HL-L2350DW" in printers
        mock_cups_connection.getPrinters.assert_called_once()

    def test_get_printers_error(self):
        """Test get_printers error handling."""
        client = CupsClient()
        mock_conn = MagicMock()
        mock_conn.getPrinters.side_effect = Exception("CUPS error")
        mock_conn.getServer.return_value = "localhost"
        client._connection = mock_conn
        client._connected_at = time.monotonic()

        with pytest.raises(CupsClientError):
            client.get_printers()

    def test_get_jobs(self, mock_cups_connection):
        """Test getting print jobs."""
        client = CupsClient()
        client._connection = mock_cups_connection
        client._connected_at = time.monotonic()
        mock_cups_connection.getServer.return_value = "localhost"

        jobs = client.get_jobs()

        assert 1 in jobs
        mock_cups_connection.getJobs.assert_called_once()

    def test_cancel_job(self, mock_cups_connection):
        """Test canceling a job."""
        client = CupsClient()
        client._connection = mock_cups_connection
        client._connected_at = time.monotonic()
        mock_cups_connection.getServer.return_value = "localhost"

        result = client.cancel_job(1)

        assert result is True
        mock_cups_connection.cancelJob.assert_called_once_with(1, purge=False)

    def test_cancel_job_error(self):
        """Test cancel job error handling."""
        client = CupsClient()
        mock_conn = MagicMock()
        mock_conn.cancelJob.side_effect = Exception("Job not found")
        mock_conn.getServer.return_value = "localhost"
        client._connection = mock_conn
        client._connected_at = time.monotonic()

        with pytest.raises(CupsClientError):
            client.cancel_job(999)

    def test_get_default_printer(self, mock_cups_connection):
        """Test getting default printer."""
        mock_cups_connection.getDefault.return_value = "Brother_HL-L2350DW"
        mock_cups_connection.getServer.return_value = "localhost"
        client = CupsClient()
        client._connection = mock_cups_connection
        client._connected_at = time.monotonic()

        default = client.get_default_printer()

        assert default == "Brother_HL-L2350DW"

    def test_print_test_page(self, mock_cups_connection):
        """Test printing a test page."""
        mock_cups_connection.printTestPage.return_value = 42
        mock_cups_connection.getServer.return_value = "localhost"
        client = CupsClient()
        client._connection = mock_cups_connection
        client._connected_at = time.monotonic()

        job_id = client.print_test_page("Brother_HL-L2350DW")

        assert job_id == 42
        mock_cups_connection.printTestPage.assert_called_once_with("Brother_HL-L2350DW")

    def test_print_test_page_error(self):
        """Test print_test_page error handling."""
        client = CupsClient()
        mock_conn = MagicMock()
        mock_conn.printTestPage.side_effect = Exception("Printer error")
        mock_conn.getServer.return_value = "localhost"
        client._connection = mock_conn
        client._connected_at = time.monotonic()

        with pytest.raises(CupsClientError):
            client.print_test_page("NonExistent")


class TestConnectWithRetry:
    """Tests for connect_with_retry method."""

    @patch("printserver.cups_client.time.sleep")
    def test_succeeds_on_first_attempt(self, mock_sleep, mock_cups_module):
        """Test retry succeeds immediately when CUPS is available."""
        mock_conn = MagicMock()
        mock_cups_module.Connection.return_value = mock_conn

        client = CupsClient()
        client.connect_with_retry(max_retries=3)

        assert client.is_connected
        mock_cups_module.Connection.assert_called_once()
        mock_sleep.assert_not_called()

    @patch("printserver.cups_client.time.sleep")
    def test_succeeds_on_third_attempt(self, mock_sleep, mock_cups_module):
        """Test retry succeeds after initial failures."""
        mock_conn = MagicMock()
        mock_cups_module.Connection.side_effect = [
            Exception("Connection refused"),
            Exception("Connection refused"),
            mock_conn,
        ]

        client = CupsClient()
        client.connect_with_retry(max_retries=3, base_delay=1.0)

        assert client.is_connected
        assert mock_cups_module.Connection.call_count == 3
        # Verify exponential backoff: 1.0s, 2.0s
        assert mock_sleep.call_count == 2
        mock_sleep.assert_any_call(1.0)
        mock_sleep.assert_any_call(2.0)

    @patch("printserver.cups_client.time.sleep")
    def test_exhausts_retries(self, mock_sleep, mock_cups_module):
        """Test raises after all retries are exhausted."""
        mock_cups_module.Connection.side_effect = Exception("Connection refused")

        client = CupsClient()
        with pytest.raises(CupsClientError) as exc_info:
            client.connect_with_retry(max_retries=2, base_delay=0.1)

        assert "after 3 attempts" in str(exc_info.value)
        assert mock_cups_module.Connection.call_count == 3  # 1 initial + 2 retries

    @patch("printserver.cups_client.time.sleep")
    def test_backoff_capped_at_max_delay(self, mock_sleep, mock_cups_module):
        """Test exponential backoff is capped at max_delay."""
        mock_cups_module.Connection.side_effect = [
            Exception("fail"),
            Exception("fail"),
            Exception("fail"),
            MagicMock(),
        ]

        client = CupsClient()
        client.connect_with_retry(max_retries=3, base_delay=1.0, max_delay=3.0)

        # Delays: min(1*2^0, 3)=1.0, min(1*2^1, 3)=2.0, min(1*2^2, 3)=3.0
        mock_sleep.assert_any_call(1.0)
        mock_sleep.assert_any_call(2.0)
        mock_sleep.assert_any_call(3.0)


class TestEnsureConnected:
    """Tests for ensure_connected method."""

    def test_reuses_existing_healthy_connection(self):
        """Test existing healthy connection is reused."""
        mock_conn = MagicMock()
        mock_conn.getServer.return_value = "localhost"

        client = CupsClient()
        client._connection = mock_conn
        client._connected_at = time.monotonic()

        client.ensure_connected()

        # Should NOT create a new connection - just ping
        mock_conn.getServer.assert_called_once()

    @patch("printserver.cups_client.time.sleep")
    def test_reconnects_on_stale_connection(self, mock_sleep, mock_cups_module):
        """Test stale connection triggers reconnection."""
        new_conn = MagicMock()
        mock_cups_module.Connection.return_value = new_conn

        client = CupsClient()
        client._connection = MagicMock()
        # Set connected_at to way in the past (stale)
        client._connected_at = time.monotonic() - MAX_CONNECTION_AGE - 10

        client.ensure_connected()

        # Should create a new connection
        mock_cups_module.Connection.assert_called_once()
        assert client._connection is new_conn

    @patch("printserver.cups_client.time.sleep")
    def test_reconnects_on_dead_connection(self, mock_sleep, mock_cups_module):
        """Test dead connection (getServer fails) triggers reconnection."""
        dead_conn = MagicMock()
        dead_conn.getServer.side_effect = Exception("Connection lost")
        new_conn = MagicMock()
        mock_cups_module.Connection.return_value = new_conn

        client = CupsClient()
        client._connection = dead_conn
        client._connected_at = time.monotonic()

        client.ensure_connected()

        mock_cups_module.Connection.assert_called_once()
        assert client._connection is new_conn

    @patch("printserver.cups_client.time.sleep")
    def test_connects_when_no_connection(self, mock_sleep, mock_cups_module):
        """Test connects from scratch when no connection exists."""
        mock_conn = MagicMock()
        mock_cups_module.Connection.return_value = mock_conn

        client = CupsClient()
        client.ensure_connected()

        mock_cups_module.Connection.assert_called_once()
        assert client._connection is mock_conn


class TestIsStaleness:
    """Tests for connection staleness detection."""

    def test_is_stale_when_never_connected(self):
        """Test new client reports stale (no connection time)."""
        client = CupsClient()
        assert client.is_stale is True

    def test_is_stale_when_old(self):
        """Test connection older than MAX_CONNECTION_AGE is stale."""
        client = CupsClient()
        client._connected_at = time.monotonic() - MAX_CONNECTION_AGE - 1
        assert client.is_stale is True

    def test_not_stale_when_recent(self):
        """Test fresh connection is not stale."""
        client = CupsClient()
        client._connected_at = time.monotonic()
        assert client.is_stale is False


class TestStateFunctions:
    """Tests for state conversion functions."""

    def test_get_printer_state_string_idle(self):
        assert get_printer_state_string(PRINTER_STATE_IDLE) == "idle"

    def test_get_printer_state_string_processing(self):
        assert get_printer_state_string(PRINTER_STATE_PROCESSING) == "printing"

    def test_get_printer_state_string_stopped(self):
        assert get_printer_state_string(PRINTER_STATE_STOPPED) == "stopped"

    def test_get_printer_state_string_unknown(self):
        assert get_printer_state_string(999) == "offline"

    def test_get_job_state_string_pending(self):
        assert get_job_state_string(JOB_STATE_PENDING) == "pending"

    def test_get_job_state_string_processing(self):
        assert get_job_state_string(JOB_STATE_PROCESSING) == "processing"

    def test_get_job_state_string_completed(self):
        assert get_job_state_string(JOB_STATE_COMPLETED) == "completed"

    def test_get_job_state_string_canceled(self):
        assert get_job_state_string(JOB_STATE_CANCELED) == "canceled"

    def test_get_job_state_string_unknown(self):
        assert get_job_state_string(999) == "unknown"
