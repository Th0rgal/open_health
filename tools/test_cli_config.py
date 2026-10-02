"""Smoke checks for CLI env configuration and fractional timezone defaults."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

BINARY = os.environ.get('OURA_TEST_BINARY', str(Path('target/debug/oura').resolve()))

class CliConfigTests(unittest.TestCase):
    def test_env_paths_and_explicit_override_do_not_load_key_for_saved_data(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            key = root / 'oura.key'
            key.write_text('invalid-key')
            env = dict(os.environ, OURA_DB_FILE=str(root / 'env.db'), OURA_KEY_FILE=str(key))
            result = subprocess.run([BINARY, 'events'], env=env, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertTrue((root / 'env.db').is_file())
            result = subprocess.run([BINARY, '--db', str(root / 'flag.db'), 'events'], env=env,
                                    capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertTrue((root / 'flag.db').is_file())

    @unittest.skipUnless(os.name == 'posix', 'local defaults use the Unix timezone')
    def test_fractional_local_timezone_defaults(self):
        for zone, expected in [('Asia/Kolkata', '5.5'), ('Asia/Kathmandu', '5.75'), ('UTC', '0')]:
            result = subprocess.run([BINARY, 'dashboard', '--help'], env=dict(os.environ, TZ=zone),
                                    capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            line = next(line for line in result.stdout.splitlines() if '--tz-offset' in line)
            self.assertIn(f'[default: {expected}]', line)

if __name__ == '__main__':
    unittest.main()
