"""Tests for the in-memory log ring buffer handler."""

import logging

from web.app import RingBufferHandler


class TestRingBufferHandler:
    """Tests for RingBufferHandler."""

    def test_stores_log_entries(self):
        """Test handler stores log entries."""
        handler = RingBufferHandler(capacity=10)
        handler.setFormatter(logging.Formatter("%(message)s"))

        logger = logging.getLogger("test.ring_buffer")
        logger.addHandler(handler)
        logger.setLevel(logging.DEBUG)

        logger.info("test message 1")
        logger.warning("test message 2")

        entries = handler.get_entries()
        assert len(entries) == 2
        assert entries[0]["level"] == "INFO"
        assert entries[0]["message"] == "test message 1"
        assert entries[1]["level"] == "WARNING"
        assert entries[1]["message"] == "test message 2"

        logger.removeHandler(handler)

    def test_respects_capacity(self):
        """Test ring buffer drops oldest entries when full."""
        handler = RingBufferHandler(capacity=3)
        handler.setFormatter(logging.Formatter("%(message)s"))

        logger = logging.getLogger("test.ring_buffer_cap")
        logger.addHandler(handler)
        logger.setLevel(logging.DEBUG)

        for i in range(5):
            logger.info(f"msg {i}")

        entries = handler.get_entries()
        assert len(entries) == 3
        assert entries[0]["message"] == "msg 2"
        assert entries[1]["message"] == "msg 3"
        assert entries[2]["message"] == "msg 4"

        logger.removeHandler(handler)

    def test_get_entries_with_count(self):
        """Test get_entries returns only requested count."""
        handler = RingBufferHandler(capacity=10)
        handler.setFormatter(logging.Formatter("%(message)s"))

        logger = logging.getLogger("test.ring_buffer_count")
        logger.addHandler(handler)
        logger.setLevel(logging.DEBUG)

        for i in range(5):
            logger.info(f"msg {i}")

        entries = handler.get_entries(count=2)
        assert len(entries) == 2
        assert entries[0]["message"] == "msg 3"
        assert entries[1]["message"] == "msg 4"

        logger.removeHandler(handler)

    def test_empty_buffer(self):
        """Test get_entries on empty buffer."""
        handler = RingBufferHandler(capacity=10)
        entries = handler.get_entries()
        assert entries == []

    def test_entry_has_expected_fields(self):
        """Test each entry contains timestamp, level, logger, message."""
        handler = RingBufferHandler(capacity=10)
        handler.setFormatter(logging.Formatter("%(message)s"))

        logger = logging.getLogger("test.ring_buffer_fields")
        logger.addHandler(handler)
        logger.setLevel(logging.DEBUG)

        logger.error("test error")

        entries = handler.get_entries()
        entry = entries[0]
        assert "timestamp" in entry
        assert entry["level"] == "ERROR"
        assert "test.ring_buffer_fields" in entry["logger"]
        assert entry["message"] == "test error"

        logger.removeHandler(handler)
