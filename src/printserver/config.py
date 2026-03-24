"""Configuration management for the print server."""

import configparser
import logging
import logging.handlers
import os
from dataclasses import dataclass
from pathlib import Path
from typing import Optional

# Default configuration paths
DEFAULT_CONFIG_DIR = Path("/etc/printserver")
DEFAULT_CONFIG_FILE = DEFAULT_CONFIG_DIR / "config.ini"

# Constants
DEFAULT_WEB_PORT = 5000
DEFAULT_WEB_HOST = "0.0.0.0"
DEFAULT_CUPS_HOST = "localhost"
DEFAULT_CUPS_PORT = 631
LOG_FORMAT = "%(asctime)s - %(name)s - %(levelname)s - %(message)s"
LOG_FILE = Path("/var/log/printserver/app.log")


@dataclass
class WebConfig:
    """Web interface configuration."""

    host: str = DEFAULT_WEB_HOST
    port: int = DEFAULT_WEB_PORT
    debug: bool = False


@dataclass
class CupsConfig:
    """CUPS connection configuration."""

    host: str = DEFAULT_CUPS_HOST
    port: int = DEFAULT_CUPS_PORT


@dataclass
class ServerConfig:
    """Main server configuration."""

    web: WebConfig
    cups: CupsConfig
    log_level: str = "INFO"
    printer_name: Optional[str] = None

    @classmethod
    def from_file(cls, config_path: Optional[Path] = None) -> "ServerConfig":
        """Load configuration from INI file.

        Args:
            config_path: Path to config file. Uses default if not specified.

        Returns:
            ServerConfig instance with loaded values.
        """
        config = configparser.ConfigParser()
        path = config_path or DEFAULT_CONFIG_FILE

        # Start with defaults
        web_config = WebConfig()
        cups_config = CupsConfig()
        log_level = "INFO"
        printer_name = None

        if path.exists():
            config.read(path)

            # Web section
            if "web" in config:
                web_config = WebConfig(
                    host=config.get("web", "host", fallback=DEFAULT_WEB_HOST),
                    port=config.getint("web", "port", fallback=DEFAULT_WEB_PORT),
                    debug=config.getboolean("web", "debug", fallback=False),
                )

            # CUPS section
            if "cups" in config:
                cups_config = CupsConfig(
                    host=config.get("cups", "host", fallback=DEFAULT_CUPS_HOST),
                    port=config.getint("cups", "port", fallback=DEFAULT_CUPS_PORT),
                )

            # Server section
            if "server" in config:
                log_level = config.get("server", "log_level", fallback="INFO")
                printer_name = config.get("server", "printer_name", fallback=None)

        return cls(
            web=web_config,
            cups=cups_config,
            log_level=log_level,
            printer_name=printer_name,
        )

    @classmethod
    def from_env(cls) -> "ServerConfig":
        """Load configuration from environment variables.

        Environment variables:
            PRINTSERVER_WEB_HOST: Web interface host
            PRINTSERVER_WEB_PORT: Web interface port
            PRINTSERVER_WEB_DEBUG: Enable debug mode
            PRINTSERVER_CUPS_HOST: CUPS server host
            PRINTSERVER_CUPS_PORT: CUPS server port
            PRINTSERVER_LOG_LEVEL: Logging level
            PRINTSERVER_PRINTER_NAME: Default printer name

        Returns:
            ServerConfig instance with loaded values.
        """
        web_config = WebConfig(
            host=os.environ.get("PRINTSERVER_WEB_HOST", DEFAULT_WEB_HOST),
            port=int(os.environ.get("PRINTSERVER_WEB_PORT", DEFAULT_WEB_PORT)),
            debug=os.environ.get("PRINTSERVER_WEB_DEBUG", "").lower() == "true",
        )

        cups_config = CupsConfig(
            host=os.environ.get("PRINTSERVER_CUPS_HOST", DEFAULT_CUPS_HOST),
            port=int(os.environ.get("PRINTSERVER_CUPS_PORT", DEFAULT_CUPS_PORT)),
        )

        return cls(
            web=web_config,
            cups=cups_config,
            log_level=os.environ.get("PRINTSERVER_LOG_LEVEL", "INFO"),
            printer_name=os.environ.get("PRINTSERVER_PRINTER_NAME"),
        )


def setup_logging(level: str = "INFO") -> logging.Logger:
    """Configure logging for the print server.

    Sets up two handlers on the root logger:
    - StreamHandler (stdout → journald via systemd)
    - RotatingFileHandler writing to LOG_FILE with immediate flush per record

    The file handler is critical for post-freeze debugging: journald buffers
    writes in RAM and loses them on a hard freeze, but FileHandler calls
    flush() after every emit(), so each line reaches the OS page cache
    immediately and survives all but the hardest power-loss scenarios.

    Args:
        level: Logging level (DEBUG, INFO, WARNING, ERROR, CRITICAL)

    Returns:
        Configured logger instance.
    """
    log_level = getattr(logging, level.upper(), logging.INFO)
    formatter = logging.Formatter(LOG_FORMAT)

    root = logging.getLogger()
    root.setLevel(log_level)

    # Only add handlers if none exist yet (guard against double-init in tests)
    if not root.handlers:
        stream_handler = logging.StreamHandler()
        stream_handler.setFormatter(formatter)
        root.addHandler(stream_handler)

    # Always add the file handler if it isn't already present — this is the
    # handler that survives hard freezes.  Silently skip if the log directory
    # doesn't exist (e.g. during unit tests running outside the Pi).
    if not any(
        isinstance(h, logging.handlers.RotatingFileHandler) for h in root.handlers
    ):
        try:
            LOG_FILE.parent.mkdir(parents=True, exist_ok=True)
            file_handler = logging.handlers.RotatingFileHandler(
                LOG_FILE,
                maxBytes=5 * 1024 * 1024,  # 5 MB per file
                backupCount=3,
                encoding="utf-8",
            )
            file_handler.setFormatter(formatter)
            root.addHandler(file_handler)
        except OSError:
            # Non-fatal: fall back to journald-only logging
            logging.getLogger(__name__).warning(
                "Could not open log file %s — logging to journald only", LOG_FILE
            )

    return logging.getLogger("printserver")


def get_config() -> ServerConfig:
    """Get server configuration.

    Loads from file first, then overrides with environment variables.

    Returns:
        ServerConfig instance.
    """
    # Try loading from file first
    config = ServerConfig.from_file()

    # Override with environment variables if set
    if os.environ.get("PRINTSERVER_WEB_HOST"):
        config.web.host = os.environ["PRINTSERVER_WEB_HOST"]
    if os.environ.get("PRINTSERVER_WEB_PORT"):
        config.web.port = int(os.environ["PRINTSERVER_WEB_PORT"])
    if os.environ.get("PRINTSERVER_WEB_DEBUG"):
        config.web.debug = os.environ["PRINTSERVER_WEB_DEBUG"].lower() == "true"
    if os.environ.get("PRINTSERVER_CUPS_HOST"):
        config.cups.host = os.environ["PRINTSERVER_CUPS_HOST"]
    if os.environ.get("PRINTSERVER_CUPS_PORT"):
        config.cups.port = int(os.environ["PRINTSERVER_CUPS_PORT"])
    if os.environ.get("PRINTSERVER_LOG_LEVEL"):
        config.log_level = os.environ["PRINTSERVER_LOG_LEVEL"]
    if os.environ.get("PRINTSERVER_PRINTER_NAME"):
        config.printer_name = os.environ["PRINTSERVER_PRINTER_NAME"]

    return config
