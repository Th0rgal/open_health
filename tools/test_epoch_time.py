import sqlite3
import unittest

from _common import clock_events_relation
from epoch_time import build_epochs, is_dated, latest_unix, make_unix_s


class RingClockTests(unittest.TestCase):
    def test_rtc_beacon_dates_sleep_independently_of_download_time(self):
        for previous_boot in ([], [(5_000_000, 0x42, '{"unix_time":1700000000}', 1_700_000_000)]):
            with self.subTest(previous_boot=bool(previous_boot)):
                epochs = build_epochs(previous_boot + [
                    (672_400, 1, '{}', 1_700_100_000),
                    (1_000_000, 0x85, '{"unix_time":1700050000}', 1_700_100_000),
                ])
                unix_s = make_unix_s(epochs)
                # Sleep ends at the beacon; the download happens 50_000 s later.
                self.assertEqual(unix_s(672_400, 1_700_100_000), 1_700_017_240)
                self.assertEqual(unix_s(1_000_000, 1_700_100_000), 1_700_050_000)
                self.assertEqual(latest_unix(epochs), 1_700_050_000)
                if previous_boot:
                    self.assertEqual(unix_s(5_000_000, 1_700_000_000), 1_700_000_000)


    def test_new_boot_is_not_projected_through_old_boot_nor_dated_to_download(self):
        epochs = build_epochs([
            (5_000_000, 0x42, '{"unix_time":1700000000}', 1_700_000_000),
            (5_100_000, 1, '{}', 1_700_000_000),
            (10, 1, '{}', 1_700_100_000),
            (300_000, 0x76, '{}', 1_700_100_000),
        ])
        self.assertFalse(is_dated(epochs, 300_000, 1_700_100_000))
        self.assertNotEqual(make_unix_s(epochs)(300_000, 1_700_100_000),
                            1_700_000_000 + (300_000 - 5_000_000) / 10.0)
        self.assertTrue(is_dated(epochs, 5_100_000, 1_700_000_000))

    def test_erratic_counter_between_disagreeing_anchors_is_undated(self):
        # 28 hours of ds in one wall-clock hour between the first two anchors, then a
        # healthy pocket between the next two (mirror of the Rust test).
        epochs = build_epochs([
            (20_000, 1, '{}', 1_700_000_000),
            (20_928, 0x42, '{"unix_time":1699900000}', 1_700_000_000),
            (500_000, 1, '{}', 1_700_000_000),
            (1_032_193, 0x85, '{"unix_time":1699903712}', 1_700_000_000),
            (1_100_000, 1, '{}', 1_700_000_000),
            (1_133_000, 0x85, '{"unix_time":1699913793}', 1_700_000_000),
            (1_200_000, 1, '{}', 1_700_000_000),
        ])
        self.assertFalse(is_dated(epochs, 500_000, 1_700_000_000))
        self.assertTrue(is_dated(epochs, 1_100_000, 1_700_000_000))
        self.assertTrue(is_dated(epochs, 1_200_000, 1_700_000_000))
        self.assertTrue(is_dated(epochs, 20_000, 1_700_000_000))

    def test_stalled_counter_uses_download_time_to_pick_the_anchor_side(self):
        before, after = (47_893_458, 1_700_000_000), (61_076_535, 1_701_462_200)
        epochs = build_epochs([
            (before[0], 0x42, '{"unix_time":%d}' % before[1], before[1] + 60),
            (52_000_000, 1, '{}', 1_700_366_820),
            (after[0], 0x42, '{"unix_time":%d}' % after[1], after[1] + 60),
        ])
        unix_s = make_unix_s(epochs)
        self.assertTrue(is_dated(epochs, 52_000_000, 1_700_366_820))
        self.assertAlmostEqual(unix_s(52_000_000, 1_700_366_820), before[1] + (52_000_000 - before[0]) / 10.0)
        self.assertAlmostEqual(unix_s(52_000_000, after[1] + 60), after[1] - (after[0] - 52_000_000) / 10.0)

    def test_phone_anchor_dates_new_boot(self):
        epochs = build_epochs([
            (5_000_000, 0x42, '{"unix_time":1700000000}', 1_700_000_000),
            (10, 1, '{}', 1_700_100_000),
            (705_000, 0x42, '{"unix_time":1700100000,"source":"phone"}', 1_700_100_000),
        ])
        start = 705_000 - (1_700_100_000 - 1_700_045_580) * 10
        self.assertTrue(is_dated(epochs, start, 1_700_100_000))
        self.assertEqual(make_unix_s(epochs)(start, 1_700_100_000), 1_700_045_580)


    def test_ring_start_marks_the_stall_when_pre_stall_events_download_late(self):
        # Synced, died on an empty battery, booted on the charger without
        # resetting ds, synced again later: pre-stall events were downloaded after it.
        before, boot, after = (8_040_603, 1_700_000_000), 24_041_617, (25_724_127, 1_702_000_530)
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


    def test_phone_anchor_table_joins_the_clock_stream(self):
        con = sqlite3.connect(":memory:")
        con.executescript("""
            CREATE TABLE events (id INTEGER PRIMARY KEY, serial, tag, name, ring_timestamp, body,
                                 decoded_json, captured_unix);
            CREATE TABLE phone_anchors (id INTEGER PRIMARY KEY, serial, ring_timestamp, unix_time,
                                        captured_unix);
            INSERT INTO events VALUES (1, 'S', 65, 'ring_start', 600000, x'', '{}', 1700099580);
            INSERT INTO phone_anchors VALUES (1, 'S', 705000, 1700100000, 1700100000);
        """)
        self.assertEqual(clock_events_relation(con), "events")
        con.executescript("""
            CREATE VIEW events_with_anchors AS
            SELECT id, serial, tag, name, ring_timestamp, body, decoded_json, captured_unix FROM events
            UNION ALL
            SELECT 4503599627370496 + id, serial, 66, 'time_sync', ring_timestamp, x'',
                   '{"unix_time":' || unix_time || ',"source":"phone"}', captured_unix FROM phone_anchors;
        """)
        self.assertEqual(clock_events_relation(con), "events_with_anchors")
        rows = con.execute(
            "SELECT ring_timestamp, tag, decoded_json, captured_unix FROM events_with_anchors "
            "ORDER BY captured_unix, id").fetchall()
        self.assertEqual(make_unix_s(build_epochs(rows))(672_400, 1_700_100_000), 1_700_096_740)


if __name__ == '__main__':
    unittest.main()
