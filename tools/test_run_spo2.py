"""--night must pick the newest bedtime across ring reboots and only its boot's samples."""
import contextlib
import io
import json
import sqlite3
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

import run_spo2


def _db(path):
    con = sqlite3.connect(path)
    con.execute("""CREATE TABLE events (id INTEGER PRIMARY KEY AUTOINCREMENT, serial TEXT NOT NULL,
                   tag INTEGER NOT NULL, name TEXT NOT NULL, ring_timestamp INTEGER NOT NULL,
                   body BLOB NOT NULL, decoded_json TEXT, captured_unix INTEGER NOT NULL)""")
    rows = [  # (tag, name, ring_timestamp, decoded_json) in sync order
        (65, "ring_start", 0, "{}"),
        (118, "bedtime_period", 5000, json.dumps({"bedtime_start_ds": 5000, "bedtime_end_ds": 9000})),
        (0, "spo2_r_pi_event", 600, json.dumps({"r": [0.40]})),   # old boot, inside the new night's counter window
        (0, "spo2_r_pi_event", 6000, json.dumps({"r": [0.50]})),  # old boot, old night
        (65, "ring_start", 10, "{}"),                              # reboot: counter restarts
        (118, "bedtime_period", 100, json.dumps({"bedtime_start_ds": 100, "bedtime_end_ds": 900})),
        (0, "spo2_r_pi_event", 600, json.dumps({"r": [0.60]})),   # new boot, new night
    ]
    for i, (tag, name, ts, js) in enumerate(rows):
        con.execute("INSERT INTO events (serial, tag, name, ring_timestamp, body, decoded_json, captured_unix) "
                    "VALUES ('S', ?, ?, ?, ?, ?, ?)", (tag, name, ts, bytes([i]), js, 1_793_000_000 + i))
    con.commit()
    con.close()


class RunSpo2NightTests(unittest.TestCase):
    def test_night_uses_newest_bedtime_and_only_its_boot(self):
        with tempfile.TemporaryDirectory() as d:
            db = str(Path(d) / "oura.db")
            _db(db)
            out = io.StringIO()
            with mock.patch.object(sys, "argv", ["run_spo2.py", db, "--night"]), contextlib.redirect_stdout(out):
                run_spo2.main()
            text = out.getvalue()
            self.assertIn("— 1 samples", text)
            self.assertIn("r: mean 0.600", text)


if __name__ == "__main__":
    unittest.main()
