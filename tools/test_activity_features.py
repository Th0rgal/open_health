import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from activity_features import decoder_to_aad


class ActivityFeatureTests(unittest.TestCase):
    def test_android_stepmotion_order_with_ring_vector(self):
        # Anonymized decoder output extracted from a real Ring 5 hike on 2026-07-12.
        decoded = [
            882.927429, 0.358594, 0.338672, 684.296265, 1.824423,
            0.638126, 2.131653, 0.012854, 0.045422, 0.003906, 0.117188,
        ]
        self.assertEqual(
            decoder_to_aad(decoded),
            [
                2.131653, 0.012854, 0.003906, 0.117188, 0.045422,
                0.638126, 1.824423, 882.927429, 684.296265, 0.358594, 0.338672,
            ],
        )


if __name__ == "__main__":
    unittest.main()
