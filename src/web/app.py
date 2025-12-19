"""Flask application factory for the print server web interface."""

import logging
import os
from flask import Flask

from printserver.config import get_config, setup_logging

logger = logging.getLogger(__name__)


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
    )

    # Apply any overrides
    if config_override:
        app.config.update(config_override)

    # Setup logging
    setup_logging(server_config.log_level)

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
