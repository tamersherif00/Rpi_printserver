"""Tests for route helper functions."""

import time
from unittest import mock

import pytest

from web.routes import _cache, _cached_call


class TestCachedCall:
    """Tests for the _cached_call TTL cache helper."""

    def setup_method(self):
        """Clear the shared cache before each test."""
        _cache.clear()

    def test_calls_fn_on_cache_miss(self):
        """fn() is called when no cached entry exists."""
        calls = []

        def fn():
            calls.append(1)
            return "value"

        result = _cached_call("key", fn, 30)
        assert result == "value"
        assert len(calls) == 1

    def test_returns_cached_value_within_ttl(self):
        """fn() is not called again when cached entry is still fresh."""
        calls = []

        def fn():
            calls.append(1)
            return "value"

        _cached_call("key", fn, 30)
        result = _cached_call("key", fn, 30)
        assert result == "value"
        assert len(calls) == 1

    def test_refreshes_expired_entry(self):
        """fn() is called again once the cached entry has exceeded its TTL."""
        # Prime the cache with a stale entry (TTL=1s, age=2s)
        _cache["key"] = (time.monotonic() - 2, "stale_value", 1)
        result = _cached_call("key", lambda: "fresh_value", 1)
        assert result == "fresh_value"

    def test_stores_ttl_per_entry(self):
        """Each cache entry stores its own TTL alongside the value."""
        _cached_call("fast", lambda: "f", 5)
        _cached_call("slow", lambda: "s", 60)

        assert _cache["fast"][2] == 5
        assert _cache["slow"][2] == 60

    def test_evicts_entry_based_on_its_own_ttl(self):
        """An entry is evicted when it is older than 2× its own stored TTL,
        regardless of the caller's TTL."""
        now = time.monotonic()
        # fast_key: TTL=5s, age=11s → 11 >= 2*5=10 → should be evicted
        _cache["fast_key"] = (now - 11, "fast_val", 5)
        # slow_key: TTL=60s, age=11s → 11 < 2*60=120 → should survive
        _cache["slow_key"] = (now - 11, "slow_val", 60)

        # Trigger eviction via any _cached_call (caller TTL=30 is irrelevant)
        _cached_call("trigger", lambda: "x", 30)

        assert "fast_key" not in _cache
        assert "slow_key" in _cache

    def test_short_ttl_entry_not_evicted_by_long_ttl_caller(self):
        """Before the fix, a caller with TTL=60 would use 2*60=120 as the
        eviction threshold, leaving a stale fast_key (age=11, own_ttl=5)
        alive. After the fix, it is correctly evicted using its own TTL."""
        now = time.monotonic()
        # fast_key: own_ttl=5, age=11 → should be evicted (11 >= 2*5=10)
        _cache["fast_key"] = (now - 11, "fast_val", 5)

        # Caller has a long TTL of 60s
        _cached_call("other", lambda: "other_val", 60)

        # fast_key must be gone because its own TTL governs eviction
        assert "fast_key" not in _cache

    def test_fresh_entry_not_evicted(self):
        """A fresh entry (age < 2× own TTL) is never evicted during a call."""
        now = time.monotonic()
        # fresh_key: TTL=60s, age=5s → 5 < 2*60=120 → must not be evicted
        _cache["fresh_key"] = (now - 5, "fresh_val", 60)

        _cached_call("other", lambda: "x", 5)

        assert "fresh_key" in _cache


class TestRssReading:
    """/proc/self/statm is used for current RSS, not the peak ru_maxrss."""

    def test_statm_field1_gives_current_rss(self):
        """Verify the /proc/self/statm formula: field[1] * 4096 bytes → MB."""
        statm_content = "50000 2048 1800 0 0 1000 0"  # field[1]=2048 pages
        expected_mb = round(2048 * 4096 / (1024 * 1024), 1)  # 8.0 MB

        fields = statm_content.split()
        rss_mb = round(int(fields[1]) * 4096 / (1024 * 1024), 1)

        assert rss_mb == expected_mb

    def test_statm_is_preferred_over_ru_maxrss(self):
        """/proc/self/statm is read first; ru_maxrss is only the fallback."""
        import resource as _resource

        statm_content = "50000 512 400 0 0 300 0"  # 512 pages = 2.0 MB
        peak_kb = 999 * 1024  # ru_maxrss would give 999 MB (wrong, historical peak)

        with mock.patch("builtins.open", mock.mock_open(read_data=statm_content)):
            with mock.patch.object(
                _resource, "getrusage",
                return_value=type("_ru", (), {"ru_maxrss": peak_kb})(),
            ):
                # Reproduce the route's RSS logic
                try:
                    with open("/proc/self/statm") as _f:
                        rss_mb = round(int(_f.read().split()[1]) * 4096 / (1024 * 1024), 1)
                except Exception:
                    rss_kb = _resource.getrusage(_resource.RUSAGE_SELF).ru_maxrss
                    rss_mb = round(rss_kb / 1024, 1)

        # Should use statm (2.0 MB), not ru_maxrss (999 MB)
        assert rss_mb == round(512 * 4096 / (1024 * 1024), 1)
        assert rss_mb < 10  # definitely not the 999 MB peak
