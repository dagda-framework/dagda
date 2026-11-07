"""Cleanup must never remove database storage without confirmed shutdown."""
from pathlib import Path
import signal
import subprocess
import tempfile
import unittest
from unittest.mock import patch
from support import RuntimeFixture


class FixtureCleanupTests(unittest.TestCase):
    def fixture(self, root):
        fixture = RuntimeFixture()
        fixture.temporary = Path(root) / 'owned'
        fixture.temporary.mkdir()
        fixture.database = fixture.temporary / 'postgres'
        fixture.database.mkdir()
        fixture.initialized = True
        fixture.env = {}
        return fixture

    def test_confirmed_shutdown_allows_removal_and_restores_signal_handler(self):
        with tempfile.TemporaryDirectory() as root:
            fixture = self.fixture(root)
            handler = signal.getsignal(signal.SIGINT)
            with patch('support.subprocess.run', return_value=subprocess.CompletedProcess([], 0)) as run:
                fixture.__exit__(None, None, None)
            self.assertEqual(run.call_count, 2)  # status then stop, both scoped to owned DB
            self.assertFalse(fixture.temporary.exists())
            self.assertEqual(signal.getsignal(signal.SIGINT), handler)

    def test_failed_shutdown_preserves_storage(self):
        with tempfile.TemporaryDirectory() as root:
            fixture = self.fixture(root)
            with patch('support.subprocess.run', side_effect=[subprocess.CompletedProcess([], 0), OSError('stop failed')]):
                with self.assertRaises(OSError):
                    fixture.__exit__(None, None, None)
            self.assertTrue(fixture.database.is_dir())

    def test_unknown_database_state_preserves_storage(self):
        with tempfile.TemporaryDirectory() as root:
            fixture = self.fixture(root)
            with patch('support.subprocess.run', return_value=subprocess.CompletedProcess([], 1)):
                with self.assertRaises(RuntimeError):
                    fixture.__exit__(None, None, None)
            self.assertTrue(fixture.database.is_dir())


if __name__ == '__main__':
    unittest.main()
