import unittest
from sleep_inputs import aligned_stages, collect_inputs


class SleepInputTests(unittest.TestCase):
    def test_model_time_is_not_stretched_to_whole_night(self):
        self.assertEqual(aligned_stages([60000, 90000], [2, 3], 0, 120000), [0, 0, 2, 3])
        self.assertEqual(aligned_stages([-30000, 0, 30000], [4, 1, 2], 0, 60000), [1, 2])

    def test_bad_outputs_fail_instead_of_inventing_stages(self):
        for ts, codes in [([0], [1, 2]), ([30000, 0], [1, 2]), ([0], [8])]:
            with self.assertRaises(ValueError):
                aligned_stages(ts, codes, 0, 60000)

    def test_boot_overlap_and_firmware_quality(self):
        rows = [(100, 0x80, {"ibi_ms": [800, 900], "quality": [0, 1]}, 0),
                (100, 0x60, {"ibi_ms": [1000], "amplitude": [9]}, 86400000),
                (110, 0x47, {"motion_seconds": 2}, 0)]
        beats, motion, temp = collect_inputs(rows, 0, 600, 0, lambda ds, cu: ds * 100 + cu)
        self.assertEqual([beat[3] for beat in beats], [0, 1])
        self.assertEqual(motion, [(11000, 2)])
        self.assertEqual(temp, [])


if __name__ == '__main__':
    unittest.main()
