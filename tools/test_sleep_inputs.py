import unittest
from sleep_inputs import aligned_stages, collect_inputs


class SleepInputTests(unittest.TestCase):
    def test_model_time_is_not_stretched_to_whole_night(self):
        self.assertEqual(aligned_stages([90000.0, 120000.0], [2, 3], 0, 120000), [0, 0, 2, 3])
        self.assertEqual(aligned_stages([0, 30000, 60000], [4, 1, 2], 0, 60000), [1, 2])

    def test_epochs_are_stamped_with_their_end_time(self):
        # SleepNet's real grid: first epoch ends 30 s after bedtime, last one at or
        # just past its end. A full night must cover every cell (no "incomplete").
        self.assertEqual(aligned_stages([30000, 60000, 90000, 120000], [1, 2, 3, 4], 0, 120000), [1, 2, 3, 4])
        self.assertEqual(aligned_stages([30000, 60000, 90000, 120000], [1, 2, 3, 4], 0, 100000), [1, 2, 3, 4])

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

    def test_audited_window_79784184_80059324_epoch_end_produces_918_complete_cells(self):
        # Audited reproduction: start_ds=79784184, end_ds=80059324 (duration = 275140 ds = 27514 s = 917.133 epochs).
        # SleepNet stamps each 30 s epoch with its END timestamp in ms, producing 918 epochs
        # starting at start_ms + 30000 and ending at start_ms + 918 * 30000.
        start_ms = 79784184 * 100
        end_ms = 80059324 * 100
        ts = [start_ms + (i + 1) * 30000 for i in range(918)]
        raw_stages = [2] * 918
        aligned = aligned_stages(ts, raw_stages, start_ms, end_ms)
        self.assertEqual(len(aligned), 918)
        self.assertNotIn(0, aligned)

    def test_epoch_time_multi_reboot_stall_and_undated_reasons(self):
        from epoch_time import build_epochs, is_dated, make_unix_s, undated_reason
        cap = 1789195500
        epochs = build_epochs([
            (47893458, 0x42, '{"unix_time":1787733221}', 1787733300),
            (49912254, 0x41, '{}', cap),
            (53000000, 0x76, '{}', cap),
            (57660709, 0x41, '{}', cap),
            (61076535, 0x42, '{"unix_time":1789195418}', cap),
        ])
        unix_s = make_unix_s(epochs)
        self.assertTrue(is_dated(epochs, 48500000, cap))
        self.assertFalse(is_dated(epochs, 53000000, cap))
        self.assertIsNone(unix_s(53000000, cap))
        self.assertEqual(undated_reason(epochs, 53000000, cap), "ambiguous_reboot_stall")
        self.assertTrue(is_dated(epochs, 59000000, cap))


if __name__ == '__main__':
    unittest.main()
