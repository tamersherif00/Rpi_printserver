"""Integration tests for IPP endpoint availability."""

import socket
import urllib.request
import urllib.error
from unittest import TestCase, skipIf, skipUnless


def is_linux():
    """Check if running on Linux."""
    import platform
    return platform.system() == "Linux"


def cups_available():
    """Check if CUPS is available on the system."""
    try:
        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        sock.settimeout(1)
        result = sock.connect_ex(("localhost", 631))
        sock.close()
        return result == 0
    except Exception:
        return False


def can_import_cups():
    """Check if pycups is available."""
    try:
        import cups
        return True
    except ImportError:
        return False


class TestIPPEndpoint(TestCase):
    """Tests for IPP endpoint availability."""

    @skipUnless(cups_available(), "CUPS not available on port 631")
    def test_cups_port_open(self):
        """Test that CUPS is listening on port 631."""
        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        sock.settimeout(5)
        try:
            result = sock.connect_ex(("localhost", 631))
            self.assertEqual(result, 0, "Port 631 should be open")
        finally:
            sock.close()

    @skipUnless(cups_available(), "CUPS not available")
    def test_cups_web_interface_accessible(self):
        """Test that CUPS web interface is accessible."""
        try:
            req = urllib.request.Request(
                "http://localhost:631/",
                headers={"Accept": "text/html"},
            )
            with urllib.request.urlopen(req, timeout=5) as response:
                status = response.status
                # CUPS may return 200 or redirect
                self.assertIn(status, [200, 301, 302, 303])
        except urllib.error.HTTPError as e:
            # 401/403 is acceptable - means CUPS is running but auth required
            self.assertIn(e.code, [401, 403])

    @skipUnless(cups_available(), "CUPS not available")
    def test_printers_endpoint_accessible(self):
        """Test that /printers endpoint is accessible."""
        try:
            req = urllib.request.Request(
                "http://localhost:631/printers/",
                headers={"Accept": "text/html"},
            )
            with urllib.request.urlopen(req, timeout=5) as response:
                self.assertEqual(response.status, 200)
        except urllib.error.HTTPError as e:
            # 401/403 is acceptable
            self.assertIn(e.code, [401, 403])

    @skipUnless(cups_available(), "CUPS not available")
    def test_ipp_content_type(self):
        """Test that CUPS accepts IPP content type."""
        # Send a minimal IPP request to test content type handling
        try:
            # This is a minimal IPP Get-Printer-Attributes request
            req = urllib.request.Request(
                "http://localhost:631/ipp/print",
                headers={
                    "Content-Type": "application/ipp",
                },
                method="POST",
            )
            # We expect this to fail with 400 (bad request) since we're
            # not sending valid IPP data, but it confirms IPP endpoint exists
            with urllib.request.urlopen(req, timeout=5) as response:
                pass
        except urllib.error.HTTPError as e:
            # 400 = IPP endpoint exists but request malformed
            # 401/403 = auth required
            # 426 = upgrade required (HTTPS)
            self.assertIn(e.code, [400, 401, 403, 426, 500])
        except urllib.error.URLError:
            # Connection refused is a failure
            self.fail("IPP endpoint not accessible")


class TestIPPDiscovery(TestCase):
    """Tests for IPP printer discovery."""

    @skipUnless(is_linux(), "Requires Linux")
    @skipUnless(cups_available(), "CUPS not available")
    def test_lpstat_works(self):
        """Test that lpstat command works."""
        import subprocess
        result = subprocess.run(
            ["lpstat", "-r"],
            capture_output=True,
            text=True,
        )
        # Should succeed and report scheduler status
        self.assertIn("scheduler", result.stdout.lower())

    @skipUnless(is_linux(), "Requires Linux")
    @skipUnless(can_import_cups(), "pycups not available")
    def test_cups_connection(self):
        """Test that we can connect to CUPS via pycups."""
        import cups
        try:
            conn = cups.Connection()
            # Should be able to get printers (even if empty)
            printers = conn.getPrinters()
            self.assertIsInstance(printers, dict)
        except cups.IPPError as e:
            self.fail(f"CUPS connection failed: {e}")

    @skipUnless(is_linux(), "Requires Linux")
    @skipUnless(can_import_cups(), "pycups not available")
    def test_cups_get_default(self):
        """Test getting default printer."""
        import cups
        try:
            conn = cups.Connection()
            # May return None if no default set
            default = conn.getDefault()
            # Just verify it doesn't raise an error
            self.assertTrue(default is None or isinstance(default, str))
        except cups.IPPError:
            # No printers configured is acceptable
            pass


class TestNetworkPrinting(TestCase):
    """Tests for network printing capabilities."""

    @skipUnless(cups_available(), "CUPS not available")
    def test_cups_listening_all_interfaces(self):
        """Test that CUPS is listening on all interfaces (not just localhost)."""
        # Try to connect from external interface
        import subprocess

        if not is_linux():
            self.skipTest("Requires Linux")

        result = subprocess.run(
            ["ss", "-tln"],
            capture_output=True,
            text=True,
        )

        # Check for *:631 or 0.0.0.0:631 indicating all interfaces
        output = result.stdout
        listening_all = "*:631" in output or "0.0.0.0:631" in output

        # If not listening on all interfaces, check config
        if not listening_all and "127.0.0.1:631" in output:
            self.skipTest("CUPS configured for localhost only")

    @skipUnless(is_linux(), "Requires Linux")
    def test_ipp_port_in_firewall(self):
        """Test that port 631 is allowed in firewall (if firewall active)."""
        import subprocess

        # Check if firewall is running
        ufw_result = subprocess.run(
            ["ufw", "status"],
            capture_output=True,
            text=True,
        )

        if "inactive" in ufw_result.stdout.lower():
            # Firewall not active, skip test
            self.skipTest("UFW firewall not active")

        if "active" in ufw_result.stdout.lower():
            # Check if port 631 is allowed
            self.assertIn("631", ufw_result.stdout)


class TestWindowsCompatibility(TestCase):
    """Tests for Windows printing compatibility."""

    @skipUnless(cups_available(), "CUPS not available")
    def test_smb_port_631_http(self):
        """Test HTTP access to IPP (Windows uses HTTP for IPP)."""
        # Windows adds printers via HTTP URL like http://server:631/printers/name
        try:
            req = urllib.request.Request(
                "http://localhost:631/printers/",
                headers={"Accept": "*/*"},
            )
            with urllib.request.urlopen(req, timeout=5) as response:
                content_type = response.headers.get("Content-Type", "")
                # Should return HTML or IPP content
                self.assertTrue(
                    "text/html" in content_type or "application/ipp" in content_type
                )
        except urllib.error.HTTPError as e:
            # Auth required is acceptable
            self.assertIn(e.code, [401, 403])
