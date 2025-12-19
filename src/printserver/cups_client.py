"""CUPS client wrapper for printer communication."""

import logging
from typing import Any, Optional

logger = logging.getLogger(__name__)

# CUPS states mapping
PRINTER_STATE_IDLE = 3
PRINTER_STATE_PROCESSING = 4
PRINTER_STATE_STOPPED = 5

JOB_STATE_PENDING = 3
JOB_STATE_HELD = 4
JOB_STATE_PROCESSING = 5
JOB_STATE_STOPPED = 6
JOB_STATE_CANCELED = 7
JOB_STATE_ABORTED = 8
JOB_STATE_COMPLETED = 9


class CupsClientError(Exception):
    """Exception raised for CUPS client errors."""

    pass


class CupsClient:
    """Wrapper for CUPS connection and operations."""

    def __init__(self, host: str = "localhost", port: int = 631):
        """Initialize CUPS client.

        Args:
            host: CUPS server hostname.
            port: CUPS server port.
        """
        self.host = host
        self.port = port
        self._connection: Optional[Any] = None

    def connect(self) -> None:
        """Establish connection to CUPS server.

        Raises:
            CupsClientError: If connection fails.
        """
        try:
            import cups

            self._connection = cups.Connection(host=self.host)
            logger.info(f"Connected to CUPS at {self.host}:{self.port}")
        except ImportError:
            logger.warning("pycups not available, using mock connection")
            self._connection = None
        except Exception as e:
            logger.error(f"Failed to connect to CUPS: {e}")
            raise CupsClientError(f"Failed to connect to CUPS: {e}") from e

    def disconnect(self) -> None:
        """Close CUPS connection."""
        self._connection = None
        logger.info("Disconnected from CUPS")

    @property
    def connection(self) -> Any:
        """Get active CUPS connection.

        Returns:
            CUPS connection object.

        Raises:
            CupsClientError: If not connected.
        """
        if self._connection is None:
            raise CupsClientError("Not connected to CUPS server")
        return self._connection

    @property
    def is_connected(self) -> bool:
        """Check if connected to CUPS.

        Returns:
            True if connected, False otherwise.
        """
        return self._connection is not None

    def get_printers(self) -> dict[str, dict[str, Any]]:
        """Get all configured printers.

        Returns:
            Dictionary of printer names to printer attributes.

        Raises:
            CupsClientError: If operation fails.
        """
        try:
            return self.connection.getPrinters()
        except Exception as e:
            logger.error(f"Failed to get printers: {e}")
            raise CupsClientError(f"Failed to get printers: {e}") from e

    def get_printer_attributes(self, printer_name: str) -> dict[str, Any]:
        """Get detailed attributes for a printer.

        Args:
            printer_name: Name of the printer.

        Returns:
            Dictionary of printer attributes.

        Raises:
            CupsClientError: If operation fails.
        """
        try:
            return self.connection.getPrinterAttributes(printer_name)
        except Exception as e:
            logger.error(f"Failed to get printer attributes: {e}")
            raise CupsClientError(f"Failed to get printer attributes: {e}") from e

    def get_jobs(
        self,
        printer_name: Optional[str] = None,
        which_jobs: str = "all",
        my_jobs: bool = False,
    ) -> dict[int, dict[str, Any]]:
        """Get print jobs.

        Args:
            printer_name: Filter by printer name (optional).
            which_jobs: Filter type: 'all', 'completed', 'not-completed'.
            my_jobs: Only show current user's jobs.

        Returns:
            Dictionary of job IDs to job attributes.

        Raises:
            CupsClientError: If operation fails.
        """
        try:
            return self.connection.getJobs(
                which_jobs=which_jobs,
                my_jobs=my_jobs,
            )
        except Exception as e:
            logger.error(f"Failed to get jobs: {e}")
            raise CupsClientError(f"Failed to get jobs: {e}") from e

    def get_job_attributes(self, job_id: int) -> dict[str, Any]:
        """Get attributes for a specific job.

        Args:
            job_id: Job ID.

        Returns:
            Dictionary of job attributes.

        Raises:
            CupsClientError: If operation fails.
        """
        try:
            return self.connection.getJobAttributes(job_id)
        except Exception as e:
            logger.error(f"Failed to get job attributes: {e}")
            raise CupsClientError(f"Failed to get job attributes: {e}") from e

    def cancel_job(self, job_id: int) -> bool:
        """Cancel a print job.

        Args:
            job_id: Job ID to cancel.

        Returns:
            True if successful.

        Raises:
            CupsClientError: If operation fails.
        """
        try:
            self.connection.cancelJob(job_id)
            logger.info(f"Canceled job {job_id}")
            return True
        except Exception as e:
            logger.error(f"Failed to cancel job {job_id}: {e}")
            raise CupsClientError(f"Failed to cancel job: {e}") from e

    def get_default_printer(self) -> Optional[str]:
        """Get the default printer name.

        Returns:
            Default printer name or None.

        Raises:
            CupsClientError: If operation fails.
        """
        try:
            return self.connection.getDefault()
        except Exception as e:
            logger.error(f"Failed to get default printer: {e}")
            raise CupsClientError(f"Failed to get default printer: {e}") from e


def get_printer_state_string(state: int) -> str:
    """Convert CUPS printer state to string.

    Args:
        state: CUPS printer state integer.

    Returns:
        Human-readable state string.
    """
    states = {
        PRINTER_STATE_IDLE: "idle",
        PRINTER_STATE_PROCESSING: "printing",
        PRINTER_STATE_STOPPED: "stopped",
    }
    return states.get(state, "offline")


def get_job_state_string(state: int) -> str:
    """Convert CUPS job state to string.

    Args:
        state: CUPS job state integer.

    Returns:
        Human-readable state string.
    """
    states = {
        JOB_STATE_PENDING: "pending",
        JOB_STATE_HELD: "pending-held",
        JOB_STATE_PROCESSING: "processing",
        JOB_STATE_STOPPED: "processing-stopped",
        JOB_STATE_CANCELED: "canceled",
        JOB_STATE_ABORTED: "aborted",
        JOB_STATE_COMPLETED: "completed",
    }
    return states.get(state, "unknown")
