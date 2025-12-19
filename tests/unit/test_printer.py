"""Tests for Printer model."""

from unittest.mock import MagicMock

import pytest

from printserver.printer import (
    Printer,
    get_all_printers,
    get_printer,
    get_default_printer,
)


class TestPrinter:
    """Tests for Printer dataclass."""

    def test_from_cups_data(self):
        """Test creating Printer from CUPS data."""
        cups_data = {
            "device-uri": "usb://Brother/HL-L2350DW",
            "printer-state": 3,  # idle
            "printer-state-message": "Ready",
            "printer-is-accepting-jobs": True,
            "printer-is-shared": True,
            "printer-make-and-model": "Brother HL-L2350DW",
            "printer-location": "Office",
            "printer-info": "Main Printer",
        }

        printer = Printer.from_cups_data("Brother_HL-L2350DW", cups_data)

        assert printer.name == "Brother_HL-L2350DW"
        assert printer.uri == "usb://Brother/HL-L2350DW"
        assert printer.status == "idle"
        assert printer.status_message == "Ready"
        assert printer.is_accepting_jobs is True
        assert printer.is_shared is True
        assert printer.make_model == "Brother HL-L2350DW"
        assert printer.location == "Office"
        assert printer.info == "Main Printer"

    def test_from_cups_data_minimal(self):
        """Test creating Printer with minimal CUPS data."""
        cups_data = {}

        printer = Printer.from_cups_data("TestPrinter", cups_data)

        assert printer.name == "TestPrinter"
        assert printer.uri == ""
        assert printer.status == "offline"
        assert printer.make_model == "Unknown"
        assert printer.location is None

    def test_to_dict(self, sample_printer_data):
        """Test converting Printer to dictionary."""
        printer = Printer(**sample_printer_data)
        result = printer.to_dict()

        assert result["name"] == sample_printer_data["name"]
        assert result["uri"] == sample_printer_data["uri"]
        assert result["status"] == sample_printer_data["status"]
        assert "is_accepting_jobs" in result
        assert "make_model" in result

    def test_to_summary_dict(self, sample_printer_data):
        """Test converting Printer to summary dictionary."""
        printer = Printer(**sample_printer_data)
        result = printer.to_summary_dict()

        assert "name" in result
        assert "status" in result
        assert "status_message" in result
        assert "is_accepting_jobs" in result
        # Should not include detailed fields
        assert "uri" not in result
        assert "make_model" not in result

    def test_is_online_idle(self):
        """Test is_online for idle printer."""
        printer = Printer(
            name="Test",
            uri="usb://test",
            status="idle",
            status_message="Ready",
            is_accepting_jobs=True,
            is_shared=True,
            make_model="Test",
        )
        assert printer.is_online is True

    def test_is_online_printing(self):
        """Test is_online for printing printer."""
        printer = Printer(
            name="Test",
            uri="usb://test",
            status="printing",
            status_message="Printing",
            is_accepting_jobs=True,
            is_shared=True,
            make_model="Test",
        )
        assert printer.is_online is True

    def test_is_online_stopped(self):
        """Test is_online for stopped printer."""
        printer = Printer(
            name="Test",
            uri="usb://test",
            status="stopped",
            status_message="Stopped",
            is_accepting_jobs=False,
            is_shared=True,
            make_model="Test",
        )
        assert printer.is_online is False

    def test_is_ready_true(self):
        """Test is_ready when printer is ready."""
        printer = Printer(
            name="Test",
            uri="usb://test",
            status="idle",
            status_message="Ready",
            is_accepting_jobs=True,
            is_shared=True,
            make_model="Test",
        )
        assert printer.is_ready is True

    def test_is_ready_false_not_accepting(self):
        """Test is_ready when not accepting jobs."""
        printer = Printer(
            name="Test",
            uri="usb://test",
            status="idle",
            status_message="Ready",
            is_accepting_jobs=False,
            is_shared=True,
            make_model="Test",
        )
        assert printer.is_ready is False


class TestPrinterFunctions:
    """Tests for printer helper functions."""

    def test_get_all_printers(self, mock_cups_connection):
        """Test getting all printers."""
        mock_client = MagicMock()
        mock_client.get_printers.return_value = {
            "Brother_HL-L2350DW": {
                "printer-state": 3,
                "printer-make-and-model": "Brother",
            }
        }

        printers = get_all_printers(mock_client)

        assert len(printers) == 1
        assert printers[0].name == "Brother_HL-L2350DW"

    def test_get_all_printers_empty(self):
        """Test getting printers when none configured."""
        mock_client = MagicMock()
        mock_client.get_printers.return_value = {}

        printers = get_all_printers(mock_client)

        assert len(printers) == 0

    def test_get_printer_found(self):
        """Test getting a specific printer that exists."""
        mock_client = MagicMock()
        mock_client.get_printers.return_value = {
            "Brother_HL-L2350DW": {
                "printer-state": 3,
                "printer-make-and-model": "Brother",
            }
        }

        printer = get_printer(mock_client, "Brother_HL-L2350DW")

        assert printer is not None
        assert printer.name == "Brother_HL-L2350DW"

    def test_get_printer_not_found(self):
        """Test getting a printer that doesn't exist."""
        mock_client = MagicMock()
        mock_client.get_printers.return_value = {}

        printer = get_printer(mock_client, "NonExistent")

        assert printer is None

    def test_get_default_printer(self):
        """Test getting default printer."""
        mock_client = MagicMock()
        mock_client.get_default_printer.return_value = "Brother_HL-L2350DW"
        mock_client.get_printers.return_value = {
            "Brother_HL-L2350DW": {
                "printer-state": 3,
                "printer-make-and-model": "Brother",
            }
        }

        printer = get_default_printer(mock_client)

        assert printer is not None
        assert printer.name == "Brother_HL-L2350DW"

    def test_get_default_printer_none(self):
        """Test getting default printer when none set."""
        mock_client = MagicMock()
        mock_client.get_default_printer.return_value = None

        printer = get_default_printer(mock_client)

        assert printer is None
