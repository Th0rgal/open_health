import unittest

from epoch_time import build_epochs, is_dated, latest_unix, make_unix_s


class RingClockTests(unittest.TestCase):
    def test_rtc_beacon_dates_sleep_independently_of_download_time(self):
        for previous_boot in ([], [(5_000_000, 0x42, '{"unix_time":1788800000}', 1_788_800_000)]):
            with self.subTest(previous_boot=bool(previous_boot)):
                epochs = build_epochs(previous_boot + [
                    (672_400, 1, '{}', 1_789_056_420),
                    (1_000_000, 0x85, '{"unix_time":1789020420}', 1_789_056_420),
                ])
                unix_s = make_unix_s(epochs)
                # UTC+1: Sep 9 22:01 to Sep 10 07:07, downloaded at 17:07.
                self.assertEqual(unix_s(672_400, 1_789_056_420), 1_788_987_660)
                self.assertEqual(unix_s(1_000_000, 1_789_056_420), 1_789_020_420)
                self.assertEqual(latest_unix(epochs), 1_789_020_420)
                if previous_boot:
                    self.assertEqual(unix_s(5_000_000, 1_788_800_000), 1_788_800_000)


    def test_new_boot_is_not_projected_through_old_boot_nor_dated_to_download(self):
        epochs = build_epochs([
            (5_000_000, 0x42, '{"unix_time":1788800000}', 1_788_800_000),
            (5_100_000, 1, '{}', 1_788_800_000),
            (10, 1, '{}', 1_789_056_420),
            (300_000, 0x76, '{}', 1_789_056_420),
        ])
        self.assertFalse(is_dated(epochs, 300_000, 1_789_056_420))
        self.assertNotEqual(make_unix_s(epochs)(300_000, 1_789_056_420),
                            1_788_800_000 + (300_000 - 5_000_000) / 10.0)
        self.assertTrue(is_dated(epochs, 5_100_000, 1_788_800_000))

    def test_erratic_counter_between_disagreeing_anchors_is_undated(self):
        # 28 hours of ds in one wall-clock hour between the first two anchors, then a
        # healthy pocket between the next two (mirror of the Rust test).
        epochs = build_epochs([
            (20_000, 1, '{}', 1_783_000_000),
            (20_928, 0x42, '{"unix_time":1782939604}', 1_783_000_000),
            (500_000, 1, '{}', 1_783_000_000),
            (1_032_193, 0x85, '{"unix_time":1782943316}', 1_783_000_000),
            (1_100_000, 1, '{}', 1_783_000_000),
            (1_133_000, 0x85, '{"unix_time":1782953397}', 1_783_000_000),
            (1_200_000, 1, '{}', 1_783_000_000),
        ])
        self.assertFalse(is_dated(epochs, 500_000, 1_783_000_000))
        self.assertTrue(is_dated(epochs, 1_100_000, 1_783_000_000))
        self.assertTrue(is_dated(epochs, 1_200_000, 1_783_000_000))
        self.assertTrue(is_dated(epochs, 20_000, 1_783_000_000))

    def test_stalled_counter_uses_download_time_to_pick_the_anchor_side(self):
        before, after = (47_893_458, 1_787_733_180), (61_076_535, 1_789_195_380)
        epochs = build_epochs([
            (before[0], 0x42, '{"unix_time":%d}' % before[1], before[1] + 60),
            (52_000_000, 1, '{}', 1_788_100_000),
            (after[0], 0x42, '{"unix_time":%d}' % after[1], after[1] + 60),
        ])
        unix_s = make_unix_s(epochs)
        self.assertTrue(is_dated(epochs, 52_000_000, 1_788_100_000))
        self.assertAlmostEqual(unix_s(52_000_000, 1_788_100_000), before[1] + (52_000_000 - before[0]) / 10.0)
        self.assertAlmostEqual(unix_s(52_000_000, after[1] + 60), after[1] - (after[0] - 52_000_000) / 10.0)

    def test_phone_anchor_dates_new_boot(self):
        epochs = build_epochs([
            (5_000_000, 0x42, '{"unix_time":1788800000}', 1_788_800_000),
            (10, 1, '{}', 1_789_056_420),
            (705_000, 0x42, '{"unix_time":1789056420,"source":"phone"}', 1_789_056_420),
        ])
        start = 705_000 - (1_789_056_420 - 1_789_002_000) * 10
        self.assertTrue(is_dated(epochs, start, 1_789_056_420))
        self.assertEqual(make_unix_s(epochs)(start, 1_789_056_420), 1_789_002_000)


    def test_ring_start_marks_the_stall_when_pre_stall_events_download_late(self):
        # Synced 09-04, died on an empty battery, booted on the charger without
        # resetting ds, next sync 09-27: pre-stall events were downloaded after it.
        before, boot, after = (8_040_603, 1_788_523_149), 24_041_617, (25_724_127, 1_790_523_679)
        captured = after[1]
        epochs = build_epochs([
            (before[0], 0x42, '{"unix_time":%d,"source":"phone"}' % before[1], before[1]),
            (20_000_000, 1, '{}', captured),
            (boot, 0x41, '{}', captured),
            (25_000_000, 1, '{}', captured),
            (after[0], 0x42, '{"unix_time":%d,"source":"phone"}' % after[1], captured),
        ])
        unix_s = make_unix_s(epochs)
        self.assertAlmostEqual(unix_s(20_000_000, captured), before[1] + (20_000_000 - before[0]) / 10.0)
        self.assertAlmostEqual(unix_s(25_000_000, captured), after[1] - (after[0] - 25_000_000) / 10.0)


    def test_multiple_reboots_leave_middle_undated(self):
        rows = [(1000, 0x42, '{"unix_time":1700000000}', 1700000000),
                (2000, 0x41, '{}', 1700100000),
                (8000, 0x41, '{}', 1700100000),
                (10000, 0x42, '{"unix_time":1700100000}', 1700100000)]
        resolve = make_unix_s(build_epochs(rows))
        self.assertIsNone(resolve(5000, 1700100000))
        self.assertEqual(resolve(1500, 1700100000), 1700000050)
        self.assertEqual(resolve(9000, 1700100000), 1700099900)


if __name__ == '__main__':
    unittest.main()
