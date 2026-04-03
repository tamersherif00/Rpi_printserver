"""Printer model representing a physical printer."""

from dataclasses import dataclass
from typing import Any, Optional

from .cups_client import CupsClient, get_printer_state_string


@dataclass
class Printer:
    """Represents a physical printer connected to the system."""

    name: str
    uri: str
    status: str
    status_message: str
    is_accepting_jobs: bool
    is_shared: bool
    make_model: str
    location: Optional[str] = None
    info: Optional[str] = None

    @classmethod
    def from_cups_data(cls, name: str, data: dict[str, Any]) -> "Printer":
        """Create Printer from CUPS printer data.

        Args:
            name: Printer name.
            data: CUPS printer attributes dictionary.

        Returns:
            Printer instance.
        """
        # Try multiple attribute name variations for accepting jobs
        is_accepting = (
            data.get("printer-is-accepting-jobs")
            or data.get("printer_is_accepting_jobs")
            or False
        )
        # Handle both boolean and integer representations (1=True, 0=False)
        if isinstance(is_accepting, int):
            is_accepting = bool(is_accepting)

        return cls(
            name=name,
            uri=data.get("device-uri") or data.get("device_uri", ""),
            status=get_printer_state_string(
                data.get("printer-state") or data.get("printer_state", 0)
            ),
            status_message=(
                data.get("printer-state-message")
                or data.get("printer_state_message", "")
            ),
            is_accepting_jobs=is_accepting,
            is_shared=bool(
                data.get("printer-is-shared") or data.get("printer_is_shared", False)
            ),
            make_model=(
                data.get("printer-make-and-model")
                or data.get("printer_make_and_model", "Unknown")
            ),
            location=data.get("printer-location") or data.get("printer_location"),
            info=data.get("printer-info") or data.get("printer_info"),
        )

    def to_dict(self) -> dict[str, Any]:
        """Convert to dictionary for JSON serialization.

        Returns:
            Dictionary representation.
        """
        return {
            "name": self.name,
            "uri": self.uri,
            "status": self.status,
            "status_message": self.status_message,
            "is_accepting_jobs": self.is_accepting_jobs,
            "is_shared": self.is_shared,
            "make_model": self.make_model,
            "location": self.location,
            "info": self.info,
        }

    def to_summary_dict(self) -> dict[str, Any]:
        """Convert to summary dictionary for status display.

        Returns:
            Summary dictionary with key fields only.
        """
        return {
            "name": self.name,
            "status": self.status,
            "status_message": self.status_message,
            "is_accepting_jobs": self.is_accepting_jobs,
        }

    @property
    def is_online(self) -> bool:
        """Check if printer is online and ready.

        Returns:
            True if printer is idle or printing.
        """
        return self.status in ("idle", "printing")

    @property
    def is_ready(self) -> bool:
        """Check if printer is ready to accept jobs.

        Returns:
            True if printer is online and accepting jobs.
        """
        return self.is_online and self.is_accepting_jobs


def get_all_printers(
    cups_client: CupsClient, include_virtual: bool = True
) -> list[Printer]:
    """Get all printers from CUPS.

    Args:
        cups_client: Connected CUPS client.
        include_virtual: Include virtual printers like PDF (default: True).

    Returns:
        List of Printer instances.
    """
    printers_data = cups_client.get_printers()
    printers = [
        Printer.from_cups_data(name, data) for name, data in printers_data.items()
    ]

    # Filter out virtual printers if requested
    if not include_virtual:
        printers = [
            p
            for p in printers
            if not any(
                virtual in p.name.lower()
                for virtual in ["pdf", "cups-pdf", "virtual"]
            )
            and not p.uri.startswith("cups-pdf:")
        ]

    return printers


def get_printer(cups_client: CupsClient, name: str) -> Optional[Printer]:
    """Get a specific printer by name.

    Args:
        cups_client: Connected CUPS client.
        name: Printer name.

    Returns:
        Printer instance or None if not found.
    """
    printers_data = cups_client.get_printers()
    if name in printers_data:
        return Printer.from_cups_data(name, printers_data[name])
    return None


def get_default_printer(cups_client: CupsClient) -> Optional[Printer]:
    """Get the default printer.

    Args:
        cups_client: Connected CUPS client.

    Returns:
        Default Printer instance or None.
    """
    default_name = cups_client.get_default_printer()
    if default_name:
        return get_printer(cups_client, default_name)
    return None
