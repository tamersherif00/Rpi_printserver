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
    """Set system hostname.

    This updates both the transient hostname and the persistent hostname files.

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

    try:
        # Set transient hostname (immediate effect)
        result = subprocess.run(
            ["hostnamectl", "set-hostname", new_hostname],
            capture_output=True,
            text=True,
            timeout=10,
        )
        if result.returncode != 0:
            raise SystemUtilsError(f"Failed to set hostname: {result.stderr}")

        # Update /etc/hostname (persistent)
        with open("/etc/hostname", "w") as f:
            f.write(new_hostname + "\n")

        # Update /etc/hosts (replace old hostname with new)
        old_hostname = get_hostname()
        try:
            with open("/etc/hosts", "r") as f:
                hosts_content = f.read()

            # Replace old hostname in hosts file
            hosts_content = hosts_content.replace(
                f"127.0.1.1\t{old_hostname}", f"127.0.1.1\t{new_hostname}"
            )

            with open("/etc/hosts", "w") as f:
                f.write(hosts_content)
        except Exception as e:
            logger.warning(f"Could not update /etc/hosts: {e}")

        # Restart Avahi to broadcast new hostname
        try:
            subprocess.run(
                ["systemctl", "restart", "avahi-daemon"],
                capture_output=True,
                text=True,
                timeout=10,
            )
            logger.info("Restarted Avahi daemon to broadcast new hostname")
        except Exception as e:
            logger.warning(f"Could not restart Avahi: {e}")

        logger.info(f"Hostname successfully changed to: {new_hostname}")

    except subprocess.TimeoutExpired:
        raise SystemUtilsError("Timeout setting hostname")
    except PermissionError:
        raise SystemUtilsError(
            "Permission denied. Hostname change requires root privileges."
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
