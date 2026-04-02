"""Flask application factory for the print server web interface."""

import collections
import gc
import logging
import os
import resource
import threading
import time
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

    def __init__(self, capacity: int = 200):
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


def _make_memory_watchdog(cache: dict) -> threading.Thread:
    """Create a daemon thread that periodically forces GC and monitors RSS.

    Runs every 5 minutes. Clears the route cache if memory is critical
    (>190 MB RSS), and logs a warning above 150 MB.  The systemd unit
    enforces a hard MemoryMax=256 M; this gives an earlier safety valve
    so the Pi never OOM-freezes.

    Args:
        cache: The module-level _cache dict from routes, passed by reference
               so the watchdog can clear it without importing routes.

    Returns:
        Daemon Thread (not yet started).
    """
    INTERVAL_S = 300        # check every 5 minutes
    WARN_MB = 120           # soft warning threshold (below systemd MemoryHigh=160M)
    CRITICAL_MB = 140       # clear cache above this (gives headroom before 160M)

    def _rss_mb() -> float:
        # ru_maxrss returns the peak (maximum) RSS on Linux, not the current RSS.
        # Read current RSS from /proc/self/statm: field[1] is RSS in 4096-byte pages.
        try:
            with open("/proc/self/statm") as f:
                fields = f.read().split()
                return int(fields[1]) * 4096 / (1024 * 1024)
        except Exception:
            # Fallback: ru_maxrss is in kB on Linux (peak, not current)
            return resource.getrusage(resource.RUSAGE_SELF).ru_maxrss / 1024

    def _run():
        while True:
            time.sleep(INTERVAL_S)
            try:
                collected = gc.collect()
                rss = _rss_mb()
                logger.info(
                    "MemoryWatchdog: GC freed %d objects | RSS=%.1f MB | "
                    "cache_keys=%d",
                    collected, rss, len(cache),
                )
                if rss > CRITICAL_MB:
                    logger.warning(
                        "MemoryWatchdog CRITICAL: RSS=%.1f MB — clearing route cache", rss
                    )
                    cache.clear()
                    gc.collect()
                elif rss > WARN_MB:
                    logger.warning(
                        "MemoryWatchdog: RSS=%.1f MB approaching systemd MemoryHigh", rss
                    )
            except Exception as exc:
                logger.error("MemoryWatchdog error: %s", exc)

    return threading.Thread(target=_run, name="memory-watchdog", daemon=True)


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
    ring_handler = RingBufferHandler(capacity=200)
    ring_handler.setFormatter(logging.Formatter(
        "%(asctime)s - %(name)s - %(levelname)s - %(message)s"
    ))
    logging.getLogger("printserver").addHandler(ring_handler)
    logging.getLogger("web").addHandler(ring_handler)
    app._log_buffer = ring_handler

    # Readiness flag - set after initial CUPS connection attempt
    app._ready = False

    # One-shot before_request hook to mark the app as ready.
    # Per-thread CUPS connections are managed by get_cups_client() in routes.py;
    # creating a separate app-level connection here was dead code that held an
    # unnecessary CUPS connection.
    @app.before_request
    def _startup_check():
        if app._ready:
            return None
        app._ready = True
        logger.info("Application ready — CUPS connections managed per-thread")
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

    # Start memory watchdog (daemon thread: auto-exits with the process)
    # Pass routes._cache by reference so the watchdog can clear it under pressure.
    _watchdog = _make_memory_watchdog(routes._cache)
    _watchdog.start()
    app._memory_watchdog = _watchdog
    logger.info("Memory watchdog thread started (interval=5min)")

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
