"""Flask application factory for the print server web interface."""

import collections
import logging
import os
from datetime import datetime

from flask import Flask, request

from printserver.config import get_config, setup_logging
from printserver.cups_client import CupsClient, CupsClientError

logger = logging.getLogger(__name__)


class RingBufferHandler(logging.Handler):
    """Logging handler that stores entries in a fixed-size ring buffer.

    Provides in-memory access to recent application logs from the web UI
    without requiring journald or SSH access.
    """

    def __init__(self, capacity: int = 500):
        super().__init__()
        self._buffer: collections.deque[dict] = collections.deque(maxlen=capacity)

    def emit(self, record: logging.LogRecord) -> None:
        self._buffer.append({
            "timestamp": datetime.fromtimestamp(record.created).isoformat(),
            "level": record.levelname,
            "logger": record.name,
            "message": self.format(record),
        })

    def get_entries(self, count: int = 100) -> list[dict]:
        """Get the most recent log entries.

        Args:
            count: Maximum number of entries to return.

        Returns:
            List of log entry dicts (most recent last).
        """
        entries = list(self._buffer)
        return entries[-count:]


def create_app(config_override: dict = None) -> Flask:
    """Create and configure the Flask application.

    Args:
        config_override: Optional configuration overrides.

    Returns:
        Configured Flask application.
    """
    app = Flask(
        __name__,
        template_folder="templates",
        static_folder="static",
    )

    # Load configuration
    server_config = get_config()

    app.config.update(
        DEBUG=server_config.web.debug,
        SECRET_KEY=os.environ.get("SECRET_KEY", "dev-secret-key-change-in-production"),
        CUPS_HOST=server_config.cups.host,
        CUPS_PORT=server_config.cups.port,
        PRINTER_NAME=server_config.printer_name,
        SEND_FILE_MAX_AGE_DEFAULT=604800,  # 7-day cache for static files
        JSON_SORT_KEYS=False,  # Skip unnecessary JSON key sorting
        TEMPLATES_AUTO_RELOAD=server_config.web.debug,  # Only auto-reload in debug
    )

    # Apply any overrides
    if config_override:
        app.config.update(config_override)

    # Setup logging
    setup_logging(server_config.log_level)

    # Attach in-memory log ring buffer for web-based log viewing
    ring_handler = RingBufferHandler(capacity=500)
    ring_handler.setFormatter(logging.Formatter(
        "%(asctime)s - %(name)s - %(levelname)s - %(message)s"
    ))
    logging.getLogger("printserver").addHandler(ring_handler)
    logging.getLogger("web").addHandler(ring_handler)
    app._log_buffer = ring_handler

    # Readiness flag - set after initial CUPS connection attempt
    app._ready = False

    # One-shot before_request hook to attempt initial CUPS connection
    @app.before_request
    def _startup_check():
        if app._ready:
            return None
        app._ready = True
        # Attempt initial CUPS connection (non-blocking for the request)
        try:
            client = CupsClient(
                host=app.config.get("CUPS_HOST", "localhost"),
                port=app.config.get("CUPS_PORT", 631),
            )
            client.connect_with_retry(max_retries=2, base_delay=1.0, max_delay=5.0)
            app._cups_client = client
            logger.info("Initial CUPS connection established")
        except CupsClientError as e:
            logger.warning(f"Initial CUPS connection failed (will retry on requests): {e}")
        return None

    # Cache-Control for static assets (CSS, JS, images)
    @app.after_request
    def _set_cache_headers(response):
        if response.status_code == 200 and request.path.startswith("/static/"):
            response.headers["Cache-Control"] = "public, max-age=604800"
        return response

    # Register routes
    from . import routes

    routes.register_routes(app)

    logger.info("Print server web application initialized")

    return app


def run_server():
    """Run the Flask development server."""
    config = get_config()
    app = create_app()

    logger.info(f"Starting web server on {config.web.host}:{config.web.port}")

    app.run(
        host=config.web.host,
        port=config.web.port,
        debug=config.web.debug,
    )


if __name__ == "__main__":
    run_server()
