"""CUPS client wrapper for printer communication."""

import logging
import time
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

# Connection staleness threshold — how long before we proactively refresh
# a connection. pycups connections to localhost are cheap to hold open;
# 3600s means we only reconnect if the thread has been idle for an hour,
# rather than every 2 minutes (which flooded logs with "Connected" spam).
# Dead connections are still caught immediately by the getServer() check.
MAX_CONNECTION_AGE = 3600


class CupsClientError(Exception):
    """Exception raised for CUPS client errors."""

    pass


class CupsClient:
    """Wrapper for CUPS connection and operations with retry and self-healing."""

    def __init__(self, host: str = "localhost", port: int = 631):
        """Initialize CUPS client.

        Args:
            host: CUPS server hostname.
            port: CUPS server port.
        """
        self.host = host
        self.port = port
        self._connection: Optional[Any] = None
        self._connected_at: float = 0.0

    def connect(self) -> None:
        """Establish connection to CUPS server (single attempt).

        Raises:
            CupsClientError: If connection fails.
        """
        try:
            import cups

            self._connection = cups.Connection(host=self.host)
            self._connected_at = time.monotonic()
            logger.debug(f"Connected to CUPS at {self.host}:{self.port}")
        except ImportError:
            logger.warning("pycups not available, using mock connection")
            self._connection = None
        except Exception as e:
            logger.error(f"Failed to connect to CUPS: {e}")
            raise CupsClientError(f"Failed to connect to CUPS: {e}") from e

    def connect_with_retry(
        self,
        max_retries: int = 3,
        base_delay: float = 1.0,
        max_delay: float = 10.0,
    ) -> None:
        """Connect to CUPS with exponential backoff retry.

        Args:
            max_retries: Maximum number of retry attempts after first failure.
            base_delay: Initial delay between retries in seconds.
            max_delay: Maximum delay between retries in seconds.

        Raises:
            CupsClientError: If all connection attempts fail.
        """
        last_error = None
        for attempt in range(max_retries + 1):
            try:
                import cups

                self._connection = cups.Connection(host=self.host)
                self._connected_at = time.monotonic()
                if attempt > 0:
                    # Reconnected after a failure — worth logging at INFO
                    logger.info(
                        f"Reconnected to CUPS at {self.host}:{self.port} "
                        f"(after {attempt + 1} attempts)"
                    )
                else:
                    logger.debug(f"Connected to CUPS at {self.host}:{self.port}")
                return
            except ImportError:
                logger.warning("pycups not available, using mock connection")
                self._connection = None
                return
            except Exception as e:
                last_error = e
                if attempt < max_retries:
                    delay = min(base_delay * (2 ** attempt), max_delay)
                    logger.warning(
                        f"CUPS connection attempt {attempt + 1}/{max_retries + 1} "
                        f"failed: {e}. Retrying in {delay:.1f}s"
                    )
                    time.sleep(delay)

        logger.error(
            f"Failed to connect to CUPS after {max_retries + 1} attempts: {last_error}"
        )
        raise CupsClientError(
            f"Failed to connect to CUPS after {max_retries + 1} attempts: {last_error}"
        ) from last_error

    def ensure_connected(self) -> None:
        """Ensure a healthy CUPS connection exists, reconnecting if needed.

        Reuses existing connections when healthy. Detects stale or dead
        connections and auto-reconnects with retry.

        Raises:
            CupsClientError: If connection cannot be established.
        """
        if self._connection is not None and not self.is_stale:
            try:
                self._connection.getServer()
                return
            except Exception:
                logger.warning("CUPS connection is dead, reconnecting")
                self._connection = None

        if self._connection is not None and self.is_stale:
            logger.debug("CUPS connection is stale, reconnecting")
            self._connection = None

        self.connect_with_retry()

    def disconnect(self) -> None:
        """Close CUPS connection."""
        self._connection = None
        self._connected_at = 0.0
        logger.info("Disconnected from CUPS")

    @property
    def is_stale(self) -> bool:
        """Check if the connection has exceeded its maximum age.

        Returns:
            True if the connection is older than MAX_CONNECTION_AGE.
        """
        if self._connected_at == 0.0:
            return True
        return (time.monotonic() - self._connected_at) > MAX_CONNECTION_AGE

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
        self.ensure_connected()
        try:
            return self.connection.getPrinters()
        except CupsClientError:
            raise
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
        self.ensure_connected()
        try:
            return self.connection.getPrinterAttributes(printer_name)
        except CupsClientError:
            raise
        except Exception as e:
            logger.error(f"Failed to get printer attributes: {e}")
            raise CupsClientError(f"Failed to get printer attributes: {e}") from e

    def get_jobs(
        self,
        printer_name: Optional[str] = None,
        which_jobs: str = "all",
        my_jobs: bool = False,
        requested_attributes: Optional[list[str]] = None,
    ) -> dict[int, dict[str, Any]]:
        """Get print jobs.

        Args:
            printer_name: Filter by printer name (optional).
            which_jobs: Filter type: 'all', 'completed', 'not-completed'.
            my_jobs: Only show current user's jobs.
            requested_attributes: Specific attributes to request (optional).

        Returns:
            Dictionary of job IDs to job attributes.

        Raises:
            CupsClientError: If operation fails.
        """
        self.ensure_connected()
        try:
            # pycups getJobs() only returns a small default attribute set
            # (no timestamps).  Explicitly request the fields the UI needs.
            if not requested_attributes:
                requested_attributes = [
                    "job-id",
                    "job-name",
                    "job-originating-user-name",
                    "job-state",
                    "job-state-message",
                    "job-k-octets",
                    "job-media-sheets",
                    "job-media-sheets-completed",
                    "job-printer-uri",
                    "time-at-creation",
                    "time-at-completed",
                    "time-at-processing",
                ]

            kwargs = {
                "which_jobs": which_jobs,
                "my_jobs": my_jobs,
                "requested_attributes": requested_attributes,
            }

            jobs = self.connection.getJobs(**kwargs)

            if logger.isEnabledFor(logging.DEBUG):
                for job_id, job_data in jobs.items():
                    logger.debug(f"Job {job_id} attributes: {job_data.keys()}")

            return jobs
        except CupsClientError:
            raise
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
        self.ensure_connected()
        try:
            return self.connection.getJobAttributes(job_id)
        except CupsClientError:
            raise
        except Exception as e:
            logger.error(f"Failed to get job attributes: {e}")
            raise CupsClientError(f"Failed to get job attributes: {e}") from e

    def cancel_job(self, job_id: int, purge: bool = False) -> bool:
        """Cancel a print job.

        Args:
            job_id: Job ID to cancel.
            purge: If True, forcibly purge the job even if stuck or stopped.

        Returns:
            True if successful.

        Raises:
            CupsClientError: If operation fails.
        """
        self.ensure_connected()
        try:
            self.connection.cancelJob(job_id, purge=purge)
            logger.info(f"{'Purged' if purge else 'Canceled'} job {job_id}")
            return True
        except CupsClientError:
            raise
        except Exception as e:
            logger.error(f"Failed to cancel job {job_id}: {e}")
            raise CupsClientError(f"Failed to cancel job: {e}") from e

    def cancel_all_jobs(self, printer_name: str, purge: bool = True) -> bool:
        """Cancel all jobs on a printer, optionally purging stuck ones.

        Args:
            printer_name: Printer whose jobs to cancel.
            purge: If True, forcibly purge all jobs (default True).

        Returns:
            True if successful.

        Raises:
            CupsClientError: If operation fails.
        """
        self.ensure_connected()
        try:
            self.connection.cancelAllJobs(printer_name, purge=purge)
            logger.info(f"Canceled all jobs on '{printer_name}' (purge={purge})")
            return True
        except CupsClientError:
            raise
        except Exception as e:
            logger.error(f"Failed to cancel all jobs on '{printer_name}': {e}")
            raise CupsClientError(f"Failed to cancel all jobs: {e}") from e

    def accept_printer(self, printer_name: str) -> bool:
        """Enable a printer and make it accept jobs (cupsenable + cupsaccept).

        Args:
            printer_name: Printer name.

        Returns:
            True if successful.

        Raises:
            CupsClientError: If operation fails.
        """
        self.ensure_connected()
        try:
            self.connection.enablePrinter(printer_name)
            self.connection.acceptJobs(printer_name)
            logger.info(f"Enabled '{printer_name}' and set to accept jobs")
            return True
        except CupsClientError:
            raise
        except Exception as e:
            logger.error(f"Failed to accept jobs on '{printer_name}': {e}")
            raise CupsClientError(f"Failed to accept jobs on printer: {e}") from e

    def print_test_page(self, printer_name: str) -> int:
        """Print a CUPS test page on the specified printer.

        Args:
            printer_name: Name of the printer.

        Returns:
            CUPS job ID for the test page.

        Raises:
            CupsClientError: If operation fails.
        """
        self.ensure_connected()
        try:
            job_id = self.connection.printTestPage(printer_name)
            logger.info(f"Printed test page on '{printer_name}' (job {job_id})")
            return job_id
        except CupsClientError:
            raise
        except Exception as e:
            logger.error(f"Failed to print test page on '{printer_name}': {e}")
            raise CupsClientError(f"Failed to print test page: {e}") from e

    def get_default_printer(self) -> Optional[str]:
        """Get the default printer name.

        Returns:
            Default printer name or None.

        Raises:
            CupsClientError: If operation fails.
        """
        self.ensure_connected()
        try:
            return self.connection.getDefault()
        except CupsClientError:
            raise
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
