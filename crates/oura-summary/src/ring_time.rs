use serde_json::Value;

// A ring timestamp is a per-boot decisecond counter. `time_sync` events are the
// authoritative bridge from that counter to UTC; captured_unix is only when the
// phone downloaded the event and is therefore an epoch-selection hint/fallback.
#[derive(Clone, Debug)]
struct Epoch {
    min_ds: i64,
    max_ds: i64,
    capture_min: i64,
    capture_max: i64,
    fallback_anchor_unix: i64,
    anchors: Vec<(i64, i64)>, // (ring ds, UTC unix seconds)
}

const RESET_SLACK_DS: i64 = 6 * 3600 * 10;
// A history event cannot legitimately occur well after the phone captured it.
// A few hours tolerate clock corrections/timezone setup without allowing a replayed
// pre-reboot high ds value to fabricate weeks of future data.
const FUTURE_SLACK_S: f64 = 6.0 * 3600.0;

/// Maps the ring's rebooting relative clock onto UTC.
pub(crate) struct RingClock {
    epochs: Vec<Epoch>,
}

impl RingClock {
    pub(crate) fn from_events(events: &[(i64, u8, String, i64)]) -> Self {
        let mut epochs: Vec<Epoch> = Vec::new();
        // Store::decoded_events preserves `(captured_unix, insertion id)` order.
        // The id tie-breaker matters: a full-history drain inserts thousands of
        // events in the same second, including the backward jump at a reboot.
        for (ds, tag, json, captured) in events {
            match epochs.last_mut() {
                Some(e) if *ds >= e.max_ds - RESET_SLACK_DS => {
                    if *ds >= e.max_ds {
                        e.max_ds = *ds;
                        e.fallback_anchor_unix = *captured;
                    }
                    e.min_ds = e.min_ds.min(*ds);
                    e.capture_min = e.capture_min.min(*captured);
                    e.capture_max = e.capture_max.max(*captured);
                }
                _ => epochs.push(Epoch {
                    min_ds: *ds,
                    max_ds: *ds,
                    capture_min: *captured,
                    capture_max: *captured,
                    fallback_anchor_unix: *captured,
                    anchors: Vec::new(),
                }),
            }
            if *tag == 0x42 {
                if let Ok(value) = serde_json::from_str::<Value>(json) {
                    if let Some(unix) = value["unix_time"].as_i64() {
                        epochs.last_mut().unwrap().anchors.push((*ds, unix));
                    }
                }
            }
        }
        Self { epochs }
    }

    pub(crate) fn unix_s(&self, ds: i64, captured_unix: i64) -> f64 {
        let epoch = self.epoch_for(ds, captured_unix);
        if let Some((anchor_ds, anchor_unix)) = epoch
            .anchors
            .iter()
            .min_by_key(|(a, _)| (*a as i128 - ds as i128).unsigned_abs())
        {
            let predicted = *anchor_unix as f64 + (ds - *anchor_ds) as f64 / 10.0;
            if predicted <= captured_unix as f64 + FUTURE_SLACK_S {
                return predicted;
            }
        }

        // A cursor rebase can replay an old boot after the newer boot was already
        // stored. Duplicate anchors are ignored by SQLite, while previously unseen
        // high-ds events are appended at today's capture time and can look like a
        // continuation of the new boot. If that epoch predicts the future, select the
        // most recent globally plausible time-sync projection instead.
        if let Some(predicted) = self
            .epochs
            .iter()
            .flat_map(|e| e.anchors.iter())
            .map(|(anchor_ds, anchor_unix)| *anchor_unix as f64 + (ds - *anchor_ds) as f64 / 10.0)
            .filter(|predicted| *predicted <= captured_unix as f64 + FUTURE_SLACK_S)
            .max_by(f64::total_cmp)
        {
            return predicted;
        }

        (epoch.fallback_anchor_unix as f64 - (epoch.max_ds - ds) as f64 / 10.0)
            .min(captured_unix as f64 + FUTURE_SLACK_S)
    }

    pub(crate) fn latest_unix(&self) -> i64 {
        self.epochs
            .iter()
            .flat_map(|e| e.anchors.iter().map(|(_, unix)| *unix))
            .max()
            .unwrap_or_else(|| {
                self.epochs
                    .iter()
                    .map(|e| e.fallback_anchor_unix)
                    .max()
                    .expect("events is non-empty")
            })
    }

    pub(crate) fn total_span_ds(&self) -> i64 {
        self.epochs.iter().map(|e| e.max_ds - e.min_ds).sum()
    }

    fn epoch_for(&self, ds: i64, captured_unix: i64) -> &Epoch {
        self.epochs
            .iter()
            .filter(|e| ds >= e.min_ds - RESET_SLACK_DS && ds <= e.max_ds + RESET_SLACK_DS)
            .min_by_key(|e| {
                if captured_unix < e.capture_min {
                    (e.capture_min - captured_unix) as u64
                } else if captured_unix > e.capture_max {
                    (captured_unix - e.capture_max) as u64
                } else {
                    0
                }
            })
            .unwrap_or_else(|| self.epochs.last().expect("events is non-empty"))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn event(ds: i64, tag: u8, json: &str, captured: i64) -> (i64, u8, String, i64) {
        (ds, tag, json.into(), captured)
    }

    #[test]
    fn time_sync_wins_over_download_time() {
        let clock = RingClock::from_events(&[
            event(5_000_000, 1, "{}", 1_783_543_000),
            event(
                5_527_617,
                0x42,
                r#"{"unix_time":1783490291}"#,
                1_783_543_500,
            ),
            event(5_600_000, 1, "{}", 1_783_544_000),
        ]);
        let got = clock.unix_s(5_266_813, 1_783_543_500);
        assert!((got - 1_783_464_210.6).abs() < 0.01);
    }

    #[test]
    fn capture_time_selects_overlapping_boot_epoch() {
        let clock = RingClock {
            epochs: vec![
                Epoch {
                    min_ds: 0,
                    max_ds: 6_000_000,
                    capture_min: 1_700_000_100,
                    capture_max: 1_700_000_199,
                    fallback_anchor_unix: 199,
                    anchors: vec![(5_000_000, 1_700_000_000)],
                },
                Epoch {
                    min_ds: 0,
                    max_ds: 1_000_000,
                    capture_min: 1_800_000_200,
                    capture_max: 1_800_000_299,
                    fallback_anchor_unix: 299,
                    anchors: vec![(500_000, 1_800_000_000)],
                },
            ],
        };
        assert_eq!(clock.unix_s(400_000, 1_800_000_250), 1_799_990_000.0);
    }

    #[test]
    fn insertion_order_retains_reset_when_capture_seconds_match() {
        let clock = RingClock::from_events(&[
            event(5_000_000, 0x42, r#"{"unix_time":1700000000}"#, 300),
            event(5_100_000, 1, "{}", 300),
            event(10, 0x42, r#"{"unix_time":1800000000}"#, 300),
            event(20, 1, "{}", 300),
        ]);
        assert_eq!(clock.epochs.len(), 2);
        assert_eq!(clock.latest_unix(), 1_800_000_000);
    }

    #[test]
    fn replayed_old_boot_cannot_create_future_days() {
        let clock = RingClock::from_events(&[
            event(7_500_000, 0x42, r#"{"unix_time":1000000}"#, 2_000_000),
            event(13_000_000, 1, "{}", 2_000_000),
            event(10, 1, "{}", 2_100_000),
            event(5_500_000, 0x42, r#"{"unix_time":2200000}"#, 2_300_000),
            // Newly seen old-boot event appended by a from-zero replay.
            event(13_000_000, 1, "{}", 2_400_000),
        ]);
        assert_eq!(clock.unix_s(13_000_000, 2_400_000), 1_550_000.0);
    }
}
