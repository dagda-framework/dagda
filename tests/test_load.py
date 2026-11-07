"""Check benchmark accounting and statistics without network services."""
import os
from pathlib import Path
import tempfile
import threading
import time
import types
import unittest
from load import Histogram, Statistics, memory_trend, run_phase


class LoadMetricsTests(unittest.TestCase):
    def test_percentiles_and_overflow(self):
        histogram = Histogram()
        for milliseconds in range(1, 101):
            histogram.add(milliseconds / 1000)
        self.assertEqual(histogram.percentile(50), 50)
        self.assertEqual(histogram.percentile(95), 95)
        self.assertEqual(histogram.percentile(99), 99)
        histogram.add(75)
        self.assertEqual(histogram.maximum_ms, 75000)
        self.assertEqual(histogram.buckets[60000], 1)
        self.assertIsNone(Histogram().percentile(99))

    def test_drops_and_bad_responses_count_as_errors(self):
        stats = Statistics()
        stats.record('json', 200, None, 0.002, 0.001)
        stats.record('lookup', 503, 'http_503', 0.003, 0.002)
        stats.skip('client_capacity', 2)
        result = stats.report(elapsed=1, offered=4)
        self.assertEqual(result['error_rate'], 0.75)
        self.assertEqual(result['completed_rps'], 2)
        self.assertEqual(result['successful_rps'], 1)

    def test_memory_plateau_and_growth(self):
        def rows(growth):
            return [{'elapsed_seconds': i * 60, 'rss_kib': 10240 + i * growth, 'fds': 10} for i in range(30)]
        self.assertEqual(memory_trend(rows(0))['late_slope_mib_per_minute'], 0)
        self.assertAlmostEqual(memory_trend(rows(512))['late_slope_mib_per_minute'], 0.5)
        self.assertGreater(memory_trend(rows(512))['growth_mib'], 8)
        self.assertIsNone(memory_trend(rows(0)[:3]))

    def test_pacer_accounts_for_every_request_without_unbounded_queue(self):
        class FakeFixture:
            process = types.SimpleNamespace(pid=os.getpid())
            active = 0
            peak = 0
            lock = threading.Lock()

            def assert_alive(self):
                pass

            def inflight(self):
                return 0

            def request(self, path):
                with self.lock:
                    self.active += 1
                    self.peak = max(self.peak, self.active)
                try:
                    time.sleep(0.05)
                    body = {'status': 'ok'} if path == '/health/live' else {
                        'id': int(path[-1]), 'name': 'Dagda' if path[-1] == '1' else 'Odin'}
                    return 200, body, {}
                finally:
                    with self.lock:
                        self.active -= 1
        with tempfile.TemporaryDirectory() as directory:
            fixture = FakeFixture()
            fixture.artifacts = Path(directory)
            result = run_phase(fixture, 'accounting', 0.3, 100, 2, 0.02)
            self.assertEqual(result['offered'], 30)
            self.assertEqual(result['completed'] + sum(result['client_skipped'].values()), 30)
            self.assertGreater(sum(result['client_skipped'].values()), 0)
            self.assertLessEqual(fixture.peak, 2)
            self.assertFalse(result['errors'])


if __name__ == '__main__':
    unittest.main()
