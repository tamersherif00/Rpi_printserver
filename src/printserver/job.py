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

        # Try different timestamp attribute names
        for ts_attr in ["time-at-creation", "time_at_creation"]:
            if ts_attr in data:
                try:
                    created_at = datetime.fromtimestamp(data[ts_attr])
                    break
                except (ValueError, TypeError):
                    pass

        for ts_attr in ["time-at-completed", "time_at_completed"]:
            if ts_attr in data:
                try:
                    completed_at = datetime.fromtimestamp(data[ts_attr])
                    break
                except (ValueError, TypeError):
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

        # Get state message
        state_message = (
            data.get("job-state-message") or data.get("job_state_message", "")
        )
        if isinstance(state_message, bytes):
            state_message = state_message.decode("utf-8", errors="replace")

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
            state=state,
            state_message=state_message,
            size=size,
            pages=pages,
            pages_completed=pages_completed,
            created_at=created_at,
            completed_at=completed_at,
            printer_name=printer_name,
        )

    def to_dict(self) -> dict[str, Any]:
        """Convert to dictionary for JSON serialization.

        Returns:
            Dictionary representation.
        """
        return {
            "id": self.id,
            "title": self.title,
            "user": self.user,
            "state": self.state,
            "state_message": self.state_message,
            "size": self.size,
            "pages": self.pages,
            "pages_completed": self.pages_completed,
            "created_at": self.created_at.isoformat() if self.created_at else None,
            "completed_at": self.completed_at.isoformat() if self.completed_at else None,
            "printer_name": self.printer_name,
        }

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
) -> list[PrintJob]:
    """Get all print jobs from CUPS.

    Args:
        cups_client: Connected CUPS client.
        which_jobs: Filter type: 'all', 'completed', 'not-completed'.
        printer_name: Filter by printer name (optional).

    Returns:
        List of PrintJob instances.
    """
    jobs_data = cups_client.get_jobs(which_jobs=which_jobs)
    jobs = [PrintJob.from_cups_data(job_id, data) for job_id, data in jobs_data.items()]

    # Filter by printer if specified
    if printer_name:
        jobs = [j for j in jobs if j.printer_name == printer_name]

    # Sort by creation time (newest first)
    jobs.sort(key=lambda j: j.created_at or datetime.min, reverse=True)

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


def cancel_job(cups_client: CupsClient, job_id: int) -> bool:
    """Cancel a print job.

    Args:
        cups_client: Connected CUPS client.
        job_id: Job ID to cancel.

    Returns:
        True if successful.
    """
    job = get_job(cups_client, job_id)
    if job and job.can_cancel:
        return cups_client.cancel_job(job_id)
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
