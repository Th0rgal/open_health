"""Regression and parity checks for the AAD mobile export (requires local models)."""
import tempfile
import unittest
from pathlib import Path

import torch

from export_mobile import MODELS, repair_activity_empty_peaks


class MobileActivityTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        path = MODELS / "automatic_activity_detection_3_1_15.pt"
        if not path.exists():
            raise unittest.SkipTest("Local activity model is not installed")
        cls.original = torch.jit.load(str(path)).eval()
        cls.repaired = repair_activity_empty_peaks(torch.jit.load(str(path)).eval())
        cls.directory = tempfile.TemporaryDirectory()
        cls.addClassCleanup(cls.directory.cleanup)
        mobile_path = Path(cls.directory.name) / "activity.ptl"
        cls.repaired._save_for_lite_interpreter(str(mobile_path))
        # Round-trip the archive with full TorchScript for numerical parity.
        # StabilityTests executes its bytecode in the actual iOS lite runtime.
        cls.exported = torch.jit.load(str(mobile_path)).eval()

    @staticmethod
    def inputs(sparse):
        nan = float("nan")
        rows = 1 if sparse else 720
        return (
            torch.tensor([2026, 9, 8, 1], dtype=torch.float32),
            torch.tensor([30, 1, 1.78, 75] + [nan] * 10),
            torch.tensor([[i, 5.0 if 300 <= i < 360 else 1.2] for i in range(720)]),
            torch.tensor([[0] + [nan] * 11, [719] + [nan] * 11]),
            torch.tensor([[i, 0, 30, 0, 0, 0, nan, 10, 1] for i in range(rows)], dtype=torch.float32),
            torch.tensor([[i, 33.0] for i in range(rows)]),
            torch.tensor([[i, 70.0] for i in range(rows)]),
            None, None, torch.tensor(0.5), torch.tensor(10.0), torch.tensor(0.0),
        )

    def test_sparse_day_no_longer_throws(self):
        with torch.no_grad():
            with self.assertRaisesRegex(RuntimeError, "Input must be of ints, floats, or bools"):
                self.original(*self.inputs(sparse=True))
            for result in (self.repaired(*self.inputs(sparse=True)),
                           self.exported(*self.inputs(sparse=True))):
                self.assertEqual(tuple(result[0].shape), (0, 9))

    def test_complete_day_keeps_original_results(self):
        with torch.no_grad():
            expected = self.original(*self.inputs(sparse=False))
            for actual in (self.repaired(*self.inputs(sparse=False)),
                           self.exported(*self.inputs(sparse=False))):
                torch.testing.assert_close(actual, expected, rtol=0, atol=0, equal_nan=True)


class DayGuardTests(unittest.TestCase):
    """The pre-flight checks shared with iOS (ActivityModel.matrix / isDegenerate)."""

    def setUp(self):
        import run_activity_model as runner
        self.runner = runner

    def test_placeholder_lands_inside_the_met_window(self):
        rows = [[30.0, 60.0]]                      # heart rate before the MET span
        t = self.runner.tensor(rows, 2, window=(600.0, 700.0))
        self.assertEqual(t.shape, (2, 2))
        self.assertEqual(t[1, 0].item(), 600.0)   # placeholder sits on the first MET minute
        self.assertTrue(torch.isnan(t[1, 1]))
        t = self.runner.tensor([[650.0, 60.0]], 2, window=(600.0, 700.0))
        self.assertEqual(t.shape, (1, 2))         # nothing added when a sample is inside

    def test_reject_mirrors_model_valid_window(self):
        reject = self.runner.model_would_reject
        met = [[600.0 + i, 1.2] for i in range(13)]
        few = [[600.0, 0, 5, 0, 0, 0, float("nan"), 1, 0], [601.0, 0, 5, 0, 0, 0, float("nan"), 1, 0]]
        # 13 MET minutes but motion stops after two → fewer than 10 worn minutes → window
        # collapses to minute 0 while MET starts at 600: the model would throw.
        self.assertTrue(reject(met, few, [[600.0, 33.0]], [[600.0, 60.0]], [[600.0], [612.0]]))
        # Same data starting at midnight: window collapses to 0 but MET[0] is at 0 → fine.
        shifted = [[float(i), 1.2] for i in range(13)]
        self.assertFalse(reject(shifted, few, [[0.0, 33.0]], [[0.0, 60.0]], [[0.0], [12.0]]))
        # A full day with every channel covering the span is evaluable.
        full_motion = [[600.0 + i, 0, 30, 0, 0, 0, float("nan"), 10, 1] for i in range(13)]
        self.assertFalse(reject(met, full_motion, [[612.0, 33.0]], [[612.0, 60.0]], [[600.0], [612.0]]))
        # Model agrees: the rejected inputs throw, the accepted ones run.
        model = torch.jit.load(str(MODELS / "automatic_activity_detection_3_1_15.pt")).eval()
        nan = float("nan")
        def run(m, mo, te, hr):
            steps = [[m[0][0]] + [nan] * 11, [m[-1][0]] + [nan] * 11]
            return model(torch.tensor([2026, 4, 14, 1], dtype=torch.float32),
                         torch.tensor([30, 1, 1.78, 75] + [nan] * 10),
                         torch.tensor(m), torch.tensor(steps), torch.tensor(mo, dtype=torch.float32),
                         torch.tensor(te), torch.tensor(hr), None, None,
                         torch.tensor(0.5), torch.tensor(10.0), torch.tensor(0.0))[0]
        with torch.no_grad():
            with self.assertRaises(RuntimeError):
                run(met, few, [[600.0, 33.0]], [[600.0, 60.0]])
            self.assertEqual(tuple(run(met, full_motion, [[612.0, 33.0]], [[612.0, 60.0]]).shape)[1], 9)


if __name__ == "__main__":
    unittest.main()
