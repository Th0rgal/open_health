"""Regression tests for calibrate_scores, score_readiness and respiratory_rate edge cases."""
import contextlib
import io
import math
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

import numpy as np

import calibrate_scores
import respiratory_rate
import score_readiness


class _Curve:
    def to_dict(self):
        return {"kind": "stub"}


def _run_calibrate(rows, header, out):
    with tempfile.TemporaryDirectory() as d:
        csv_path = Path(d) / "trends.csv"
        csv_path.write_text(",".join(header) + "\n" + "\n".join(",".join(r) for r in rows) + "\n")
        argv = ["calibrate_scores.py", "--csv", str(csv_path), "--out", str(out)]
        stdout = io.StringIO()
        with mock.patch.object(sys, "argv", argv), \
             mock.patch.object(calibrate_scores, "WEIGHTS", {"Readiness Score": {"A": 0.5, "B": 0.5}}), \
             mock.patch.object(calibrate_scores, "LIVE_DRIVERS", {"A": (["x"], "mono"), "B": (["y"], "mono")}), \
             mock.patch.object(calibrate_scores, "engineer", lambda rows: rows), \
             mock.patch.object(calibrate_scores, "engineer_seq", lambda rows: rows), \
             mock.patch.object(calibrate_scores, "getval", lambda r, k: float(r[k]) if r.get(k) else None), \
             mock.patch.object(calibrate_scores, "fit_curve", lambda kind, data: _Curve()), \
             contextlib.redirect_stdout(stdout):
            calibrate_scores.main()
        return stdout.getvalue()


class CalibrateScoresTests(unittest.TestCase):
    def test_refuses_to_write_a_calibration_with_a_missing_contributor(self):
        with tempfile.TemporaryDirectory() as d:
            out = Path(d) / "params.json"
            rows = [["70", "1", "", ""] for _ in range(25)]
            with self.assertRaises(SystemExit) as raised:
                _run_calibrate(rows, ["A", "x", "B", "y"], out)
            self.assertIn("B", str(raised.exception))
            self.assertFalse(out.exists())

    def test_output_outside_the_repo_is_reported_without_error(self):
        with tempfile.TemporaryDirectory() as d:
            out = Path(d) / "params.json"
            rows = [["70", "1", "80", "2"] for _ in range(25)]
            printed = _run_calibrate(rows, ["A", "x", "B", "y"], out)
            self.assertTrue(out.exists())
            self.assertIn(str(out), printed)


class ScoreReadinessTests(unittest.TestCase):
    def test_inputs_line_renders_missing_values(self):
        day = {"hrv_avg": None, "hrv_baseline": None, "rhr_low": 52, "rhr_avg": 58,
               "recovery_index_h": 3.5, "temp_dev": None}
        line = score_readiness.format_inputs(day)
        self.assertIn("HRV —/—ms", line)
        self.assertIn("tempΔ —", line)

    def test_inputs_line_formats_present_values(self):
        day = {"hrv_avg": 61.4, "hrv_baseline": 55.2, "rhr_low": 52, "rhr_avg": 58,
               "recovery_index_h": 3.5, "temp_dev": -0.123}
        line = score_readiness.format_inputs(day)
        self.assertIn("HRV 61/55ms", line)
        self.assertIn("tempΔ -0.12°C", line)


class RespiratoryRateTests(unittest.TestCase):
    def test_flat_window_has_no_dominant_frequency(self):
        self.assertIsNone(respiratory_rate._dominant_freq(np.zeros(256)))

    def test_constant_heartbeat_gives_no_breathing_rate(self):
        ibi = np.full(1800, 1000.0)
        ts = np.cumsum(ibi) / 1000.0
        avg, _, _ = respiratory_rate.respiratory_rate(ts, ibi)
        self.assertTrue(math.isnan(avg), avg)


if __name__ == "__main__":
    unittest.main()
