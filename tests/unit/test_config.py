"""Tests for configuration module."""

import os
import tempfile
from pathlib import Path

import pytest

from printserver.config import (
    ServerConfig,
    WebConfig,
    CupsConfig,
    get_config,
    setup_logging,
    DEFAULT_WEB_PORT,
    DEFAULT_WEB_HOST,
    DEFAULT_CUPS_HOST,
    DEFAULT_CUPS_PORT,
)


class TestWebConfig:
    """Tests for WebConfig dataclass."""

    def test_default_values(self):
        """Test default configuration values."""
        config = WebConfig()
        assert config.host == DEFAULT_WEB_HOST
        assert config.port == DEFAULT_WEB_PORT
        assert config.debug is False

    def test_custom_values(self):
        """Test custom configuration values."""
        config = WebConfig(host="127.0.0.1", port=8080, debug=True)
        assert config.host == "127.0.0.1"
        assert config.port == 8080
        assert config.debug is True


class TestCupsConfig:
    """Tests for CupsConfig dataclass."""

    def test_default_values(self):
        """Test default CUPS configuration."""
        config = CupsConfig()
        assert config.host == DEFAULT_CUPS_HOST
        assert config.port == DEFAULT_CUPS_PORT

    def test_custom_values(self):
        """Test custom CUPS configuration."""
        config = CupsConfig(host="cups.local", port=6310)
        assert config.host == "cups.local"
        assert config.port == 6310


class TestServerConfig:
    """Tests for ServerConfig dataclass."""

    def test_from_file_missing_file(self):
        """Test loading config when file doesn't exist."""
        config = ServerConfig.from_file(Path("/nonexistent/config.ini"))

        # Should use defaults
        assert config.web.host == DEFAULT_WEB_HOST
        assert config.web.port == DEFAULT_WEB_PORT
        assert config.cups.host == DEFAULT_CUPS_HOST
        assert config.log_level == "INFO"

    def test_from_file_with_valid_file(self):
        """Test loading config from valid INI file."""
        with tempfile.NamedTemporaryFile(mode="w", suffix=".ini", delete=False) as f:
            f.write("""
[web]
host = 192.168.1.100
port = 8080
debug = true

[cups]
host = cups.local
port = 6310

[server]
log_level = DEBUG
printer_name = MyPrinter
""")
            f.flush()

            try:
                config = ServerConfig.from_file(Path(f.name))

                assert config.web.host == "192.168.1.100"
                assert config.web.port == 8080
                assert config.web.debug is True
                assert config.cups.host == "cups.local"
                assert config.cups.port == 6310
                assert config.log_level == "DEBUG"
                assert config.printer_name == "MyPrinter"
            finally:
                os.unlink(f.name)

    def test_from_env(self):
        """Test loading config from environment variables."""
        env_vars = {
            "PRINTSERVER_WEB_HOST": "10.0.0.1",
            "PRINTSERVER_WEB_PORT": "9000",
            "PRINTSERVER_WEB_DEBUG": "true",
            "PRINTSERVER_CUPS_HOST": "remote-cups",
            "PRINTSERVER_CUPS_PORT": "6320",
            "PRINTSERVER_LOG_LEVEL": "WARNING",
            "PRINTSERVER_PRINTER_NAME": "TestPrinter",
        }

        # Set environment variables
        for key, value in env_vars.items():
            os.environ[key] = value

        try:
            config = ServerConfig.from_env()

            assert config.web.host == "10.0.0.1"
            assert config.web.port == 9000
            assert config.web.debug is True
            assert config.cups.host == "remote-cups"
            assert config.cups.port == 6320
            assert config.log_level == "WARNING"
            assert config.printer_name == "TestPrinter"
        finally:
            # Clean up environment
            for key in env_vars:
                del os.environ[key]


class TestSetupLogging:
    """Tests for logging setup."""

    def test_setup_logging_returns_logger(self):
        """Test that setup_logging returns a logger."""
        logger = setup_logging("INFO")
        assert logger is not None
        assert logger.name == "printserver"

    def test_setup_logging_levels(self):
        """Test different logging levels."""
        for level in ["DEBUG", "INFO", "WARNING", "ERROR", "CRITICAL"]:
            logger = setup_logging(level)
            assert logger is not None


class TestGetConfig:
    """Tests for get_config function."""

    def test_get_config_returns_server_config(self):
        """Test that get_config returns a ServerConfig instance."""
        config = get_config()
        assert isinstance(config, ServerConfig)
        assert isinstance(config.web, WebConfig)
        assert isinstance(config.cups, CupsConfig)

    def test_get_config_env_override(self):
        """Test that environment variables override file config."""
        os.environ["PRINTSERVER_WEB_PORT"] = "7777"

        try:
            config = get_config()
            assert config.web.port == 7777
        finally:
            del os.environ["PRINTSERVER_WEB_PORT"]
