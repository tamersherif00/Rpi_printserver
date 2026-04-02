"""Print job model representing a document in the print queue."""

from dataclasses import dataclass
from datetime import datetime
from typing import Any, Optional

from .cups_client import CupsClient, get_job_state_string


@dataclass
class PrintJob:
    """Represents a print job in the queue."""

    id: int
    title: str
    user: str
    state: str
    state_message: str
    size: int
    pages: Optional[int]
    pages_completed: int
    created_at: Optional[datetime]
    completed_at: Optional[datetime]
    printer_name: str
    origin_host: str = ""
    processing_at: Optional[datetime] = None
    state_reasons: str = ""

    @classmethod
    def from_cups_data(cls, job_id: int, data: dict[str, Any]) -> "PrintJob":
        """Create PrintJob from CUPS job data.

        Args:
            job_id: Job ID.
            data: CUPS job attributes dictionary.

        Returns:
            PrintJob instance.
        """
        # Parse timestamps - try multiple attribute names
        created_at = None
        completed_at = None
        processing_at = None

        # Try different timestamp attribute names.
        # CUPS returns 0 (Unix epoch) when a timestamp isn't set yet
        # (e.g. time-at-completed for a pending job), so treat 0 as missing.
        for ts_attr in ["time-at-creation", "time_at_creation"]:
            ts_val = data.get(ts_attr)
            if ts_val:
                try:
                    created_at = datetime.fromtimestamp(ts_val)
                    break
                except (ValueError, TypeError, OSError):
                    pass

        for ts_attr in ["time-at-completed", "time_at_completed"]:
            ts_val = data.get(ts_attr)
            if ts_val:
                try:
                    completed_at = datetime.fromtimestamp(ts_val)
                    break
                except (ValueError, TypeError, OSError):
                    pass

        for ts_attr in ["time-at-processing", "time_at_processing"]:
            ts_val = data.get(ts_attr)
            if ts_val:
                try:
                    processing_at = datetime.fromtimestamp(ts_val)
                    break
                except (ValueError, TypeError, OSError):
                    pass

        # Extract printer name from URI - try multiple attribute names
        printer_uri = data.get("job-printer-uri") or data.get("job_printer_uri", "")
        printer_name = printer_uri.split("/")[-1] if printer_uri else ""

        # Get job title - try multiple attribute names and handle byte strings
        title = data.get("job-name") or data.get("job_name", "Untitled")
        if isinstance(title, bytes):
            title = title.decode("utf-8", errors="replace")
        if not title or title == "":
            title = "Untitled"

        # Get username - try multiple attribute names
        user = (
            data.get("job-originating-user-name")
            or data.get("job_originating_user_name")
            or "unknown"
        )
        if isinstance(user, bytes):
            user = user.decode("utf-8", errors="replace")

        # Get originating host (client IP address).
        # Since DefaultAuthType=None, the username is often "anonymous" or
        # a generic Windows username.  The host IP is the reliable way to
        # identify which device sent the job.
        origin_host = (
            data.get("job-originating-host-name")
            or data.get("job_originating_host_name")
            or ""
        )
        if isinstance(origin_host, bytes):
            origin_host = origin_host.decode("utf-8", errors="replace")

        # Get state message
        state_message = (
            data.get("job-state-message") or data.get("job_state_message", "")
        )
        if isinstance(state_message, bytes):
            state_message = state_message.decode("utf-8", errors="replace")

        # Get state reasons — CUPS puts detailed failure info here like
        # "media-empty-error", "toner-low-warning", "printer-stopped".
        # Can be a string or a list of strings depending on pycups version.
        raw_reasons = (
            data.get("job-state-reasons")
            or data.get("job_state_reasons")
            or ""
        )
        if isinstance(raw_reasons, (list, tuple)):
            state_reasons = ", ".join(
                r.decode("utf-8", errors="replace") if isinstance(r, bytes) else str(r)
                for r in raw_reasons
                if str(r) != "none"
            )
        elif isinstance(raw_reasons, bytes):
            state_reasons = raw_reasons.decode("utf-8", errors="replace")
        else:
            state_reasons = str(raw_reasons) if raw_reasons and str(raw_reasons) != "none" else ""

        # Get job state - try multiple attribute names
        job_state = data.get("job-state") or data.get("job_state", 0)
        state = get_job_state_string(job_state)

        # Get page counts - try multiple attribute names
        pages = data.get("job-media-sheets") or data.get("job_media_sheets")
        pages_completed = (
            data.get("job-media-sheets-completed")
            or data.get("job_media_sheets_completed")
            or 0
        )

        # Get size - try multiple attribute names
        size_kb = data.get("job-k-octets") or data.get("job_k_octets", 0)
        size = size_kb * 1024  # Convert to bytes

        return cls(
            id=job_id,
            title=title,
            user=user,
            origin_host=origin_host,
            state=state,
            state_message=state_message,
            size=size,
            pages=pages,
            pages_completed=pages_completed,
            created_at=created_at,
            completed_at=completed_at,
            processing_at=processing_at,
            printer_name=printer_name,
            state_reasons=state_reasons,
        )

    def to_dict(self) -> dict[str, Any]:
        """Convert to dictionary for JSON serialization.

        Returns:
            Dictionary representation.
        """
        # Build a combined status detail from state_message and state_reasons.
        # state_message is CUPS's human text ("Printing page 1"),
        # state_reasons is the machine-readable detail ("media-empty-error").
        # Show whichever has useful info, or both if they differ.
        status_detail = ""
        msg = self.state_message.strip() if self.state_message else ""
        reasons = self.state_reasons.strip() if self.state_reasons else ""
        if msg and reasons and msg.lower() != reasons.lower():
            status_detail = f"{msg} ({reasons})"
        elif msg:
            status_detail = msg
        elif reasons:
            status_detail = self._humanize_reasons(reasons)

        return {
            "id": self.id,
            "title": self.title,
            "user": self.user,
            "origin_host": self.origin_host,
            "state": self.state,
            "state_message": status_detail,
            "state_reasons": self.state_reasons,
            "size": self.size,
            "size_display": self._format_size(),
            "pages": self.pages,
            "pages_completed": self.pages_completed,
            "created_at": self.created_at.isoformat() if self.created_at else None,
            "completed_at": self.completed_at.isoformat() if self.completed_at else None,
            "processing_at": self.processing_at.isoformat() if self.processing_at else None,
            "printer_name": self.printer_name,
            "duration": self._format_duration(),
        }

    @staticmethod
    def _humanize_reasons(reasons: str) -> str:
        """Convert CUPS job-state-reasons to human-readable text.

        Args:
            reasons: Comma-separated CUPS reason strings.

        Returns:
            Human-readable description.
        """
        mapping = {
            "media-empty-error": "Paper tray empty",
            "media-empty-warning": "Paper tray low",
            "media-needed": "Paper needed",
            "media-jam-error": "Paper jam",
            "toner-empty-error": "Toner empty",
            "toner-low-warning": "Toner low",
            "marker-supply-low-warning": "Ink/toner low",
            "marker-supply-empty-error": "Ink/toner empty",
            "door-open-error": "Printer door open",
            "cover-open-error": "Printer cover open",
            "printer-stopped": "Printer stopped",
            "printer-stopped-partly": "Printer partially stopped",
            "offline-error": "Printer offline",
            "connecting-to-device": "Connecting to printer",
            "cups-waiting-for-job-completed": "Waiting for printer response",
            "job-printing": "Printing",
            "job-completed-successfully": "Completed",
            "job-canceled-by-user": "Canceled by user",
            "job-canceled-at-device": "Canceled at printer",
            "aborted-by-system": "Aborted by system",
            "processing-to-stop-point": "Stopping",
        }
        parts = [r.strip() for r in reasons.split(",")]
        humanized = [mapping.get(p, p.replace("-", " ").title()) for p in parts if p]
        return ", ".join(humanized)

    def _format_size(self) -> str:
        """Format file size for display.

        Returns:
            Human-readable size string.
        """
        if self.size <= 0:
            return "-"
        if self.size < 1024:
            return f"{self.size} B"
        if self.size < 1024 * 1024:
            return f"{self.size / 1024:.1f} KB"
        return f"{self.size / (1024 * 1024):.1f} MB"

    def _format_duration(self) -> Optional[str]:
        """Calculate how long the job took (submitted to completed).

        Returns:
            Human-readable duration string, or None if not applicable.
        """
        if not self.created_at:
            return None
        end = self.completed_at or (
            datetime.now() if self.is_active else None
        )
        if not end:
            return None
        delta = end - self.created_at
        secs = int(delta.total_seconds())
        if secs < 0:
            return None
        if secs < 60:
            return f"{secs}s"
        mins = secs // 60
        secs = secs % 60
        if mins < 60:
            return f"{mins}m {secs}s"
        hours = mins // 60
        mins = mins % 60
        return f"{hours}h {mins}m"

    @property
    def is_pending(self) -> bool:
        """Check if job is waiting to be printed.

        Returns:
            True if job is pending or held.
        """
        return self.state in ("pending", "pending-held")

    @property
    def is_active(self) -> bool:
        """Check if job is currently printing.

        Returns:
            True if job is processing.
        """
        return self.state in ("processing", "processing-stopped")

    @property
    def is_complete(self) -> bool:
        """Check if job has finished.

        Returns:
            True if job is completed, canceled, or aborted.
        """
        return self.state in ("completed", "canceled", "aborted")

    @property
    def can_cancel(self) -> bool:
        """Check if job can be canceled.

        Returns:
            True if job is pending or active.
        """
        return not self.is_complete


def get_all_jobs(
    cups_client: CupsClient,
    which_jobs: str = "all",
    printer_name: Optional[str] = None,
    limit: Optional[int] = None,
) -> list[PrintJob]:
    """Get print jobs from CUPS.

    Args:
        cups_client: Connected CUPS client.
        which_jobs: Filter type: 'all', 'completed', 'not-completed'.
        printer_name: Filter by printer name (optional).
        limit: Maximum number of jobs to return after sorting (optional).
               Avoids holding a large list in memory when only a slice is needed.

    Returns:
        List of PrintJob instances, newest first.
    """
    jobs_data = cups_client.get_jobs(which_jobs=which_jobs)
    jobs = [PrintJob.from_cups_data(job_id, data) for job_id, data in jobs_data.items()]

    # Filter by printer if specified
    if printer_name:
        jobs = [j for j in jobs if j.printer_name == printer_name]

    # Sort by creation time (newest first)
    jobs.sort(key=lambda j: j.created_at or datetime.min, reverse=True)

    if limit is not None:
        jobs = jobs[:limit]

    return jobs


def get_job(cups_client: CupsClient, job_id: int) -> Optional[PrintJob]:
    """Get a specific job by ID.

    Args:
        cups_client: Connected CUPS client.
        job_id: Job ID.

    Returns:
        PrintJob instance or None if not found.
    """
    try:
        data = cups_client.get_job_attributes(job_id)
        return PrintJob.from_cups_data(job_id, data)
    except Exception:
        return None


def cancel_job(cups_client: CupsClient, job_id: int, purge: bool = False) -> bool:
    """Cancel a print job.

    Args:
        cups_client: Connected CUPS client.
        job_id: Job ID to cancel.
        purge: If True, forcibly purge even stuck/stopped jobs.

    Returns:
        True if successful.
    """
    job = get_job(cups_client, job_id)
    if job and job.can_cancel:
        return cups_client.cancel_job(job_id, purge=purge)
    return False


def get_pending_jobs(cups_client: CupsClient) -> list[PrintJob]:
    """Get all pending (not completed) jobs.

    Args:
        cups_client: Connected CUPS client.

    Returns:
        List of pending PrintJob instances.
    """
    return get_all_jobs(cups_client, which_jobs="not-completed")


def get_job_count(cups_client: CupsClient) -> int:
    """Get count of pending jobs.

    Args:
        cups_client: Connected CUPS client.

    Returns:
        Number of pending jobs.
    """
    return len(get_pending_jobs(cups_client))
