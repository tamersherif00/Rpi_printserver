"""System utilities for managing Raspberry Pi configuration."""

import logging
import subprocess
import re
from typing import Optional

logger = logging.getLogger(__name__)


class SystemUtilsError(Exception):
    """Exception raised for system utilities errors."""

    pass


def get_hostname() -> str:
    """Get current system hostname.

    Returns:
        Current hostname.

    Raises:
        SystemUtilsError: If operation fails.
    """
    try:
        result = subprocess.run(
            ["hostname"],
            capture_output=True,
            text=True,
            timeout=5,
        )
        if result.returncode == 0:
            return result.stdout.strip()
        raise SystemUtilsError(f"Failed to get hostname: {result.stderr}")
    except subprocess.TimeoutExpired:
        raise SystemUtilsError("Timeout getting hostname")
    except Exception as e:
        raise SystemUtilsError(f"Error getting hostname: {e}") from e


def validate_hostname(hostname: str) -> tuple[bool, Optional[str]]:
    """Validate hostname according to RFC 1123.

    Args:
        hostname: Hostname to validate.

    Returns:
        Tuple of (is_valid, error_message).
    """
    if not hostname:
        return False, "Hostname cannot be empty"

    if len(hostname) > 63:
        return False, "Hostname must be 63 characters or less"

    # RFC 1123: alphanumeric and hyphens, cannot start/end with hyphen
    if not re.match(r"^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$", hostname):
        return (
            False,
            "Hostname must contain only letters, numbers, and hyphens, "
            "and cannot start or end with a hyphen",
        )

    # Reserved names
    reserved = ["localhost", "localhost.localdomain"]
    if hostname.lower() in reserved:
        return False, f"'{hostname}' is a reserved hostname"

    return True, None


def set_hostname(new_hostname: str) -> None:
    """Set system hostname using a privileged helper script.

    This calls the set-hostname.sh script which runs with sudo privileges
    to update the hostname, /etc/hostname, /etc/hosts, and restart Avahi.

    Args:
        new_hostname: New hostname to set.

    Raises:
        SystemUtilsError: If operation fails or validation fails.
    """
    # Validate hostname
    is_valid, error_msg = validate_hostname(new_hostname)
    if not is_valid:
        raise SystemUtilsError(error_msg)

    logger.info(f"Setting hostname to: {new_hostname}")

    # Path to the helper script
    helper_script = "/opt/printserver/scripts/set-hostname.sh"

    try:
        # Use sudo to run the helper script
        result = subprocess.run(
            ["sudo", helper_script, new_hostname],
            capture_output=True,
            text=True,
            timeout=30,
        )

        if result.returncode != 0:
            error_output = result.stderr.strip() or result.stdout.strip()
            raise SystemUtilsError(f"Failed to set hostname: {error_output}")

        logger.info(f"Hostname successfully changed to: {new_hostname}")

    except subprocess.TimeoutExpired:
        raise SystemUtilsError("Timeout setting hostname")
    except FileNotFoundError:
        raise SystemUtilsError(
            "Hostname helper script not found. Please run install.sh"
        )
    except Exception as e:
        raise SystemUtilsError(f"Error setting hostname: {e}") from e


def requires_root() -> bool:
    """Check if current process has root privileges.

    Returns:
        True if running as root, False otherwise.
    """
    try:
        import os

        return os.geteuid() == 0
    except Exception:
        return False
