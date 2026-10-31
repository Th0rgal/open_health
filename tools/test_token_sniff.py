"""Captured Oura credentials must land in an owner-only file."""
import stat
import sys
import tempfile
import types
import unittest
from pathlib import Path
from unittest import mock

_mitm = types.ModuleType("mitmproxy")
_mitm.ctx = types.SimpleNamespace(log=types.SimpleNamespace(alert=lambda *_: None))
_mitm.http = types.SimpleNamespace(HTTPFlow=object)
sys.modules.setdefault("mitmproxy", _mitm)

import oura_token_sniff  # noqa: E402


class TokenSniffTests(unittest.TestCase):
    def test_existing_world_readable_capture_file_is_restricted(self):
        with tempfile.TemporaryDirectory() as d:
            out = Path(d) / "oura_tokens.txt"
            out.write_text("old\n")
            out.chmod(0o644)
            with mock.patch.object(oura_token_sniff, "OUT", out):
                oura_token_sniff._emit("bearer", "secret-token", "api.ouraring.com")
            self.assertEqual(stat.S_IMODE(out.stat().st_mode), 0o600)
            self.assertEqual(out.read_text(), "old\napi.ouraring.com\tbearer\tsecret-token\n")

    def test_new_capture_file_is_owner_only(self):
        with tempfile.TemporaryDirectory() as d:
            out = Path(d) / "oura_tokens.txt"
            with mock.patch.object(oura_token_sniff, "OUT", out):
                oura_token_sniff._emit("cookie", "c=1", "cloud.ouraring.com")
            self.assertEqual(stat.S_IMODE(out.stat().st_mode), 0o600)


if __name__ == "__main__":
    unittest.main()
