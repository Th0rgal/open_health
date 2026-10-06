use serde_json::Value;

// A ring timestamp is a per-boot decisecond counter. `time_sync` and `rtc_beacon`
// events are the authoritative bridge from that counter to UTC; captured_unix is
// only when the phone downloaded it and is an epoch-selection hint/fallback.
#[derive(Clone, Debug)]
struct Epoch {
    min_ds: i64,
    max_ds: i64,
    capture_min: i64,
    capture_max: i64,
    fallback_anchor_unix: i64,
    anchors: Vec<(i64, i64)>, // (ring ds, UTC unix seconds)
    anchor_sources: Vec<&'static str>,
    // `ring_start` ds values: a brownout reboot keeps counting, so this is where a
    // stalled counter lost its time.
    boots: Vec<i64>,
}

const RESET_SLACK_DS: i64 = 6 * 3600 * 10;
// Two anchors of one boot normally agree on the counter rate (10 ds per second, plus
// drift). When the counter *stalled* between them (the ring lost hours while off), the
// wall clock advanced more than the counter and the later anchor's offset applies from
// the stall on; the download time tells which side of the stall an event sits on. When
// the counter ran *faster* than wall time — a fresh ring's first days jumped weeks of ds
// in an hour — nothing between the two anchors can be placed on the calendar.
// Half an hour absorbs RTC drift and the second-granular anchors; 2 % covers long gaps.
const ANCHOR_AGREEMENT_S: f64 = 30.0 * 60.0;
const ANCHOR_AGREEMENT_FRACTION: f64 = 0.02;
// A history event cannot legitimately occur well after the phone captured it.
// A few hours tolerate clock corrections/timezone setup without allowing a replayed
// pre-reboot high ds value to fabricate weeks of future data.
const FUTURE_SLACK_S: f64 = 6.0 * 3600.0;

/// Why an event or sleep window could not be placed on the calendar.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub enum UndatedReason {
    /// The boot epoch has no `time_sync` or `rtc_beacon` anchor (and was not
    /// incrementally drained across syncs).
    MissingAnchor,
    /// Two anchors in the same boot epoch disagree because the decisecond
    /// counter advanced faster than wall-clock time between them, or the counter
    /// jumped ahead of capture time relative to its anchor.
    AcceleratedCounter,
    /// Multiple `ring_start` reboots occurred inside a stalled-anchor interval
    /// where wall time exceeded counter time, so lost time cannot be partitioned.
    AmbiguousRebootStall,
}

impl UndatedReason {
    pub fn code(self) -> &'static str {
        match self {
            UndatedReason::MissingAnchor => "missing_anchor",
            UndatedReason::AcceleratedCounter => "accelerated_counter",
            UndatedReason::AmbiguousRebootStall => "ambiguous_reboot_stall",
        }
    }

    pub fn is_recoverable_by_sync(self, is_latest_unanchored_epoch: bool) -> bool {
        match self {
            UndatedReason::MissingAnchor => is_latest_unanchored_epoch,
            UndatedReason::AcceleratedCounter | UndatedReason::AmbiguousRebootStall => false,
        }
    }

    pub fn warning_message(self, count: usize, recoverable_by_sync: bool) -> String {
        let noun = if count == 1 { "night" } else { "nights" };
        let pronoun = if count == 1 { "it" } else { "them" };
        match self {
            UndatedReason::MissingAnchor if recoverable_by_sync => format!(
                "{count} {noun} [missing_anchor] could not be placed in time because the \
                 current boot epoch has no time-sync or RTC anchor yet. Syncing while the \
                 ring remains in this boot epoch can anchor {pronoun}."
            ),
            UndatedReason::MissingAnchor => format!(
                "{count} {noun} [missing_anchor] came from an earlier boot epoch that \
                 ended before any time-sync or RTC anchor was recorded. Recovery is not \
                 possible from current evidence, and syncing again cannot retroactively \
                 anchor a prior boot."
            ),
            UndatedReason::AcceleratedCounter => format!(
                "{count} {noun} [accelerated_counter] fell in an interval where the ring \
                 counter advanced faster than wall-clock time between anchors. Recovery \
                 is not possible from current evidence, and syncing again will not repair \
                 historical counter jumps."
            ),
            UndatedReason::AmbiguousRebootStall => format!(
                "{count} {noun} [ambiguous_reboot_stall] fell between multiple ring \
                 reboots inside a stalled-clock interval where wall time exceeded counter \
                 time. Lost time cannot be partitioned across multiple reboots from \
                 current evidence, and syncing again will not resolve {pronoun}."
            ),
        }
    }
}

/// Trustworthy wall-clock history metrics derived from resolved dated observations.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct HistoryStats {
    /// Elapsed wall-clock span `(max_unix - min_unix) / 86_400` across trustworthy
    /// dated observations (`Anchor` / `Projected`), rounded to 0.1 days.
    pub elapsed_days: f64,
    /// Active observed wall-clock coverage in days (merging dated observations
    /// separated by at most 24 hours so multi-day gaps or replayed ranges do not
    /// inflate active coverage), rounded to 0.1 days.
    pub observed_coverage_days: f64,
    /// Count of distinct calendar days (in the requested UTC offset) that contain at
    /// least one trustworthy dated observation.
    pub observed_days: usize,
}

/// How an event's wall-clock time was obtained. Only `Anchor` and `Projected` are
/// trustworthy to the minute; `Fallback` is download-time arithmetic (off by up to
/// one sync gap) and `Undated` means nothing ties this boot to real time.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum ClockSource {
    Anchor,
    Projected,
    Fallback,
    Undated,
}

impl ClockSource {
    pub(crate) fn is_dated(self) -> bool {
        matches!(self, ClockSource::Anchor | ClockSource::Projected)
    }
    pub(crate) fn label(self) -> &'static str {
        match self {
            ClockSource::Anchor => "anchor",
            ClockSource::Projected => "projected",
            ClockSource::Fallback => "download_time",
            ClockSource::Undated => "undated",
        }
    }
}

enum Bracket {
    Consistent,
    /// The counter lost time between the two anchors (ring powered off).
    Stalled {
        before: (i64, i64),
        after: (i64, i64),
    },
    /// The counter advanced faster than wall time: untrustworthy.
    Erratic,
}

#[derive(Clone, Copy, Debug)]
pub(crate) struct Resolved {
    pub(crate) unix: f64,
    pub(crate) source: ClockSource,
    pub(crate) undated_reason: Option<UndatedReason>,
}

/// Maps the ring's rebooting relative clock onto UTC.
pub struct RingClock {
    epochs: Vec<Epoch>,
    // `(unix * 10 - ring_ds, epoch index)`: the UTC projection offset in deciseconds
    // of every anchor, sorted by offset so replay recovery can find the newest
    // plausible projection in O(log n) instead of scanning every anchor per event.
    anchor_offsets_ds: Vec<(i64, usize)>,
}

fn anchor_source(tag: u8, value: &Value) -> &'static str {
    if value["source"].as_str() == Some("phone") {
        "phone"
    } else if tag == 0x85 {
        "rtc_beacon"
    } else {
        "time_sync"
    }
}

impl RingClock {
    pub fn from_events(events: &[(i64, u8, String, i64)]) -> Self {
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
                    anchor_sources: Vec::new(),
                    boots: Vec::new(),
                }),
            }
            if *tag == 0x41 {
                epochs.last_mut().unwrap().boots.push(*ds);
            }
            if matches!(*tag, 0x42 | 0x85) {
                if let Ok(value) = serde_json::from_str::<Value>(json) {
                    if let Some(unix) = value["unix_time"].as_i64() {
                        let e = epochs.last_mut().unwrap();
                        e.anchors.push((*ds, unix));
                        e.anchor_sources.push(anchor_source(*tag, &value));
                    }
                }
            }
        }
        for epoch in &mut epochs {
            epoch.anchors.sort_unstable();
        }
        let mut anchor_offsets_ds = epochs
            .iter()
            .enumerate()
            .flat_map(|(idx, epoch)| {
                epoch
                    .anchors
                    .iter()
                    .map(move |(ds, unix)| (unix.saturating_mul(10).saturating_sub(*ds), idx))
            })
            .collect::<Vec<_>>();
        anchor_offsets_ds.sort_unstable();
        anchor_offsets_ds.dedup_by_key(|(offset, _)| *offset);
        Self {
            epochs,
            anchor_offsets_ds,
        }
    }

    pub fn unix_s(&self, ds: i64, captured_unix: i64) -> f64 {
        self.resolve(ds, captured_unix).unix
    }

    pub(crate) fn is_in_latest_unanchored_epoch(&self, ds: i64, captured_unix: i64) -> bool {
        let Some(last) = self.epochs.last() else {
            return false;
        };
        last.anchors.is_empty() && std::ptr::eq(self.epoch_for(ds, captured_unix), last)
    }

    pub(crate) fn resolve(&self, ds: i64, captured_unix: i64) -> Resolved {
        let epoch = self.epoch_for(ds, captured_unix);
        let mut had_in_epoch_anchor = false;
        if let Some((anchor_ds, anchor_unix)) = epoch
            .anchors
            .iter()
            .min_by_key(|(a, _)| (*a as i128 - ds as i128).unsigned_abs())
        {
            had_in_epoch_anchor = true;
            let predicted = *anchor_unix as f64 + (ds - *anchor_ds) as f64 / 10.0;
            match Self::bracket(&epoch.anchors, ds) {
                Bracket::Erratic => {
                    // Any prediction would scatter the data across fabricated days.
                    return Resolved {
                        unix: predicted,
                        source: ClockSource::Undated,
                        undated_reason: Some(UndatedReason::AcceleratedCounter),
                    };
                }
                Bracket::Stalled { before, after } => {
                    let late = after.1 as f64 - (after.0 - ds) as f64 / 10.0;
                    let early = before.1 as f64 + (ds - before.0) as f64 / 10.0;
                    // A ring_start between the anchors marks the stall exactly; without
                    // one, the download time tells which side an event sits on (wrong
                    // when pre-stall events were only downloaded after the stall).
                    let boots: Vec<_> = epoch
                        .boots
                        .iter()
                        .copied()
                        .filter(|b| *b > before.0 && *b <= after.0)
                        .collect();
                    let first = boots.iter().min().copied();
                    let boot = boots.iter().max().copied();
                    // Between multiple reboots we cannot locate the lost time.
                    if first
                        .zip(boot)
                        .is_some_and(|(first, last)| ds >= first && ds < last)
                    {
                        return Resolved {
                            unix: predicted,
                            source: ClockSource::Undated,
                            undated_reason: Some(UndatedReason::AmbiguousRebootStall),
                        };
                    }
                    let unix = match boot {
                        Some(boot) if ds >= boot => late,
                        Some(_) => early,
                        None if late <= captured_unix as f64 + FUTURE_SLACK_S => late,
                        None => early,
                    };
                    return Resolved {
                        unix,
                        source: ClockSource::Anchor,
                        undated_reason: None,
                    };
                }
                Bracket::Consistent => {}
            }
            if predicted <= captured_unix as f64 + FUTURE_SLACK_S {
                return Resolved {
                    unix: predicted,
                    source: ClockSource::Anchor,
                    undated_reason: None,
                };
            }
        }

        if had_in_epoch_anchor {
            // A cursor rebase can replay an old boot after the newer boot was already
            // stored. Duplicate anchors are ignored by SQLite, while previously unseen
            // high-ds events are appended at today's capture time and can look like a
            // continuation of the new boot. If that epoch predicts the future, select the
            // most recent globally plausible time-sync projection instead.
            if let Some(predicted) = self.latest_plausible_projection(ds, captured_unix) {
                return Resolved {
                    unix: predicted,
                    source: ClockSource::Projected,
                    undated_reason: None,
                };
            }
            let unix = (epoch.fallback_anchor_unix as f64 - (epoch.max_ds - ds) as f64 / 10.0)
                .min(captured_unix as f64 + FUTURE_SLACK_S);
            return Resolved {
                unix,
                source: ClockSource::Undated,
                undated_reason: Some(UndatedReason::AcceleratedCounter),
            };
        }

        // Download-time arithmetic is only meaningful when the phone kept up with the
        // ring: a boot drained sync after sync has a capture span comparable to its ds
        // span, so the error is bounded by one sync gap. A boot downloaded in one go
        // (a fresh ring, a from-zero replay, an old boot) would simply be dated to the
        // moment of the download, so it stays undated instead.
        let ds_span_s = (epoch.max_ds - epoch.min_ds) as f64 / 10.0;
        let capture_span_s = (epoch.capture_max - epoch.capture_min) as f64;
        let incremental = ds_span_s <= 0.0 || capture_span_s * 2.0 >= ds_span_s;
        let unix = (epoch.fallback_anchor_unix as f64 - (epoch.max_ds - ds) as f64 / 10.0)
            .min(captured_unix as f64 + FUTURE_SLACK_S);
        Resolved {
            unix,
            source: if incremental {
                ClockSource::Fallback
            } else {
                ClockSource::Undated
            },
            undated_reason: (!incremental).then_some(UndatedReason::MissingAnchor),
        }
    }

    pub fn latest_unix(&self) -> i64 {
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

    /// Compute trustworthy wall-clock history metrics from dated observations
    /// (`ClockSource::Anchor` / `ClockSource::Projected`), excluding undated epochs,
    /// accelerated counter jumps, and ambiguous reboot stalls while deduplicating
    /// replayed ranges.
    pub fn trusted_history_stats(
        &self,
        events: &[(i64, u8, String, i64)],
        tz_offset_hours: f64,
    ) -> HistoryStats {
        let tz_s = (tz_offset_hours * 3600.0).round() as i64;
        let mut dated_unix: Vec<f64> = Vec::new();
        let mut days = std::collections::BTreeSet::new();

        for (ds, _tag, _json, captured) in events {
            let r = self.resolve(*ds, *captured);
            if !r.source.is_dated() || !r.unix.is_finite() || r.unix <= 0.0 {
                continue;
            }
            dated_unix.push(r.unix);
            days.insert((r.unix as i64 + tz_s).div_euclid(86_400));
        }

        if dated_unix.is_empty() {
            return HistoryStats::default();
        }

        dated_unix.sort_by(f64::total_cmp);
        let min_u = dated_unix[0];
        let max_u = *dated_unix.last().unwrap();
        let elapsed_days = (((max_u - min_u).max(0.0) / 86_400.0) * 10.0).round() / 10.0;

        // Merge consecutive dated observations separated by at most 24 hours so
        // multi-day gaps when the ring was off do not inflate active coverage and
        // replayed ranges are never double-counted.
        const MAX_ACTIVE_GAP_S: f64 = 86_400.0;
        let mut active_s = 0.0_f64;
        let mut seg_start = dated_unix[0];
        let mut seg_end = dated_unix[0];
        for &u in &dated_unix[1..] {
            if u - seg_end <= MAX_ACTIVE_GAP_S {
                seg_end = seg_end.max(u);
            } else {
                active_s += (seg_end - seg_start).max(0.0);
                seg_start = u;
                seg_end = u;
            }
        }
        active_s += (seg_end - seg_start).max(0.0);
        let observed_coverage_days = ((active_s / 86_400.0) * 10.0).round() / 10.0;

        HistoryStats {
            elapsed_days,
            observed_coverage_days,
            observed_days: days.len(),
        }
    }

    /// Per-boot diagnostics for support exports and the apps' technical reports.
    pub(crate) fn diagnostics(&self) -> Value {
        let epochs: Vec<Value> = self
            .epochs
            .iter()
            .map(|e| {
                let mut sources = e.anchor_sources.clone();
                sources.sort_unstable();
                sources.dedup();
                serde_json::json!({
                    "min_ds": e.min_ds,
                    "max_ds": e.max_ds,
                    "span_h": ((e.max_ds - e.min_ds) as f64 / 36_000.0 * 10.0).round() / 10.0,
                    "capture_min": e.capture_min,
                    "capture_max": e.capture_max,
                    "anchors": e.anchors.len(),
                    "anchor_sources": sources,
                    "boots": e.boots.len(),
                    "latest_anchor_unix": e.anchors.iter().map(|(_, u)| *u).max(),
                })
            })
            .collect();
        serde_json::json!({ "epochs": epochs })
    }

    /// How the anchors on either side of `ds` (sorted by ds) relate. Outside the
    /// anchored range the single nearest anchor extrapolates as usual — that is how
    /// an ordinary boot's first hours are dated.
    fn bracket(anchors: &[(i64, i64)], ds: i64) -> Bracket {
        let idx = anchors.partition_point(|(a, _)| *a < ds);
        let (Some(&next), Some(prev)) = (anchors.get(idx), idx.checked_sub(1).map(|i| anchors[i]))
        else {
            return Bracket::Consistent;
        };
        if next.0 == ds {
            return Bracket::Consistent;
        }
        let wall_s = (next.1 - prev.1) as f64;
        let counter_s = (next.0 - prev.0) as f64 / 10.0;
        let tolerance = ANCHOR_AGREEMENT_S.max(counter_s * ANCHOR_AGREEMENT_FRACTION);
        if wall_s < counter_s - tolerance {
            Bracket::Erratic
        } else if wall_s > counter_s + tolerance {
            Bracket::Stalled {
                before: prev,
                after: next,
            }
        } else {
            Bracket::Consistent
        }
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

    fn latest_plausible_projection(&self, ds: i64, captured_unix: i64) -> Option<f64> {
        let max_offset = captured_unix
            .saturating_add(FUTURE_SLACK_S as i64)
            .saturating_mul(10)
            .saturating_sub(ds);
        let end = self
            .anchor_offsets_ds
            .partition_point(|(offset, _)| *offset <= max_offset);
        // Borrowing another boot's clock is only legitimate when this ds continues
        // that boot's counter. A new boot restarts near zero, so a low ds must never
        // be projected through an older boot that only ever ran at higher counts —
        // and a counter jump far beyond an older boot's max_ds must not borrow that
        // older boot either.
        self.anchor_offsets_ds[..end]
            .iter()
            .rev()
            .find(|(_, idx)| {
                let ep = &self.epochs[*idx];
                ds >= ep.min_ds - RESET_SLACK_DS && ds <= ep.max_ds + RESET_SLACK_DS
            })
            .map(|(offset, _)| ds.saturating_add(*offset) as f64 / 10.0)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn event(ds: i64, tag: u8, json: &str, captured: i64) -> (i64, u8, String, i64) {
        (ds, tag, json.into(), captured)
    }

    #[test]
    fn multiple_reboots_leave_middle_undated() {
        let clock = RingClock::from_events(&[
            event(1000, 0x42, r#"{"unix_time":1700000000}"#, 1700000000),
            event(2000, 0x41, "{}", 1700100000),
            event(8000, 0x41, "{}", 1700100000),
            event(10000, 0x42, r#"{"unix_time":1700100000}"#, 1700100000),
        ]);
        assert_eq!(clock.resolve(5000, 1700100000).source, ClockSource::Undated);
        assert_eq!(clock.resolve(1500, 1700100000).unix, 1700000050.0);
        assert_eq!(clock.resolve(9000, 1700100000).unix, 1700099900.0);
    }

    #[test]
    fn erratic_counter_between_disagreeing_anchors_is_undated() {
        // A fresh ring: the counter advanced 28 hours of ds in one wall-clock hour
        // between two time syncs, then ran normally between the next two.
        let clock = RingClock::from_events(&[
            event(20_000, 1, "{}", 1_783_000_000),
            event(20_928, 0x42, r#"{"unix_time":1782939604}"#, 1_783_000_000),
            event(500_000, 1, "{}", 1_783_000_000),
            event(
                1_032_193,
                0x85,
                r#"{"unix_time":1782943316}"#,
                1_783_000_000,
            ),
            event(1_100_000, 1, "{}", 1_783_000_000),
            event(
                1_133_000,
                0x85,
                r#"{"unix_time":1782953397}"#,
                1_783_000_000,
            ),
            event(1_200_000, 1, "{}", 1_783_000_000),
        ]);
        assert_eq!(
            clock.resolve(500_000, 1_783_000_000).source,
            ClockSource::Undated
        );
        // Inside the healthy pocket the nearest anchor dates the event as usual.
        let inside = clock.resolve(1_100_000, 1_783_000_000);
        assert_eq!(inside.source, ClockSource::Anchor);
        assert!((inside.unix - (1_782_953_397.0 - 3_300.0)).abs() < 0.01);
        // Past the last anchor, extrapolation from that anchor still applies.
        assert_eq!(
            clock.resolve(1_200_000, 1_783_000_000).source,
            ClockSource::Anchor
        );
        assert_eq!(
            clock.resolve(20_000, 1_783_000_000).source,
            ClockSource::Anchor
        );
    }

    #[test]
    fn stalled_counter_uses_download_time_to_pick_the_anchor_side() {
        // The ring lost 40 h while off between two syncs: anchors 15 days apart in ds,
        // 17 days apart in wall time. An event downloaded before the later anchor's
        // projection would allow keeps the earlier offset; one downloaded later takes
        // the later offset.
        let before = (47_893_458_i64, 1_787_733_180_i64); // 08-26 08:33
        let after = (61_076_535_i64, 1_789_195_380_i64); // 09-12 06:43
        let clock = RingClock::from_events(&[
            event(
                before.0,
                0x42,
                &format!(r#"{{"unix_time":{}}}"#, before.1),
                before.1 + 60,
            ),
            event(52_000_000, 1, "{}", 1_788_100_000),
            event(
                after.0,
                0x42,
                &format!(r#"{{"unix_time":{}}}"#, after.1),
                after.1 + 60,
            ),
        ]);
        let early = clock.resolve(52_000_000, 1_788_100_000);
        assert_eq!(early.source, ClockSource::Anchor);
        assert!(
            (early.unix - (before.1 as f64 + (52_000_000 - before.0) as f64 / 10.0)).abs() < 0.01
        );
        let late = clock.resolve(52_000_000, after.1 + 60);
        assert_eq!(late.source, ClockSource::Anchor);
        assert!((late.unix - (after.1 as f64 - (after.0 - 52_000_000) as f64 / 10.0)).abs() < 0.01);
    }

    #[test]
    fn rtc_beacon_dates_overnight_sleep_independently_of_download_time() {
        // 22:01 Sep 9 -> 07:07 Sep 10 in UTC+1, downloaded ten hours later.
        let clock = RingClock::from_events(&[
            event(672_400, 1, "{}", 1_789_056_420),
            event(
                1_000_000,
                0x85,
                r#"{"unix_time":1789020420}"#,
                1_789_056_420,
            ),
        ]);
        assert_eq!(clock.unix_s(672_400, 1_789_056_420), 1_788_987_660.0);
        assert_eq!(clock.unix_s(1_000_000, 1_789_056_420), 1_789_020_420.0);
        assert_eq!(clock.latest_unix(), 1_789_020_420);
    }

    #[test]
    fn rtc_beacon_anchors_new_boot_instead_of_reusing_old_time_sync() {
        let clock = RingClock::from_events(&[
            event(
                5_000_000,
                0x42,
                r#"{"unix_time":1788800000}"#,
                1_788_800_000,
            ),
            event(672_400, 1, "{}", 1_789_056_420),
            event(
                1_000_000,
                0x85,
                r#"{"unix_time":1789020420}"#,
                1_789_056_420,
            ),
        ]);
        assert_eq!(clock.unix_s(672_400, 1_789_056_420), 1_788_987_660.0);
        assert_eq!(clock.unix_s(5_000_000, 1_788_800_000), 1_788_800_000.0);
        assert_eq!(clock.latest_unix(), 1_789_020_420);
    }

    #[test]
    fn ring_start_marks_the_stall_when_pre_stall_events_download_late() {
        // Ring 4, Sep 2026: synced 09-04, died on an empty battery 09-23, booted on the
        // charger 09-25 without resetting ds, next sync 09-27. Every pre-stall event was
        // downloaded after the stall, so the download time cannot pick the side.
        let before = (8_040_603_i64, 1_788_523_149_i64);
        let boot = 24_041_617_i64;
        let after = (25_724_127_i64, 1_790_523_679_i64);
        let captured = after.1;
        let clock = RingClock::from_events(&[
            event(
                before.0,
                0x42,
                &format!(r#"{{"unix_time":{},"source":"phone"}}"#, before.1),
                before.1,
            ),
            event(20_000_000, 1, "{}", captured),
            event(boot, 0x41, "{}", captured),
            event(25_000_000, 1, "{}", captured),
            event(
                after.0,
                0x42,
                &format!(r#"{{"unix_time":{},"source":"phone"}}"#, after.1),
                captured,
            ),
        ]);
        let early = clock.resolve(20_000_000, captured);
        assert_eq!(early.source, ClockSource::Anchor);
        assert!(
            (early.unix - (before.1 as f64 + (20_000_000 - before.0) as f64 / 10.0)).abs() < 0.01
        );
        let late = clock.resolve(25_000_000, captured);
        assert!((late.unix - (after.1 as f64 - (after.0 - 25_000_000) as f64 / 10.0)).abs() < 0.01);
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
                    anchor_sources: vec!["time_sync"],
                    boots: Vec::new(),
                },
                Epoch {
                    min_ds: 0,
                    max_ds: 1_000_000,
                    capture_min: 1_800_000_200,
                    capture_max: 1_800_000_299,
                    fallback_anchor_unix: 299,
                    anchors: vec![(500_000, 1_800_000_000)],
                    anchor_sources: vec!["time_sync"],
                    boots: Vec::new(),
                },
            ],
            anchor_offsets_ds: vec![
                (1_700_000_000 * 10 - 5_000_000, 0),
                (1_800_000_000 * 10 - 500_000, 1),
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

    #[test]
    fn unanchored_full_drain_epoch_is_undated_not_download_time() {
        // A whole boot downloaded in one second with no time_sync/rtc_beacon: dating
        // it to the download would put the night's end at the sync time.
        let clock = RingClock::from_events(&[
            event(100_000, 1, "{}", 1_789_056_420),
            event(400_000, 0x76, "{}", 1_789_056_420),
            event(700_000, 1, "{}", 1_789_056_420),
        ]);
        let r = clock.resolve(400_000, 1_789_056_420);
        assert_eq!(r.source, ClockSource::Undated);
        assert!(!r.source.is_dated());
    }

    #[test]
    fn incrementally_drained_epoch_falls_back_to_download_time() {
        // Synced every day for three days: download time tracks ring time to within
        // a sync gap, so the fallback is usable (but flagged).
        let clock = RingClock::from_events(&[
            event(100_000, 1, "{}", 1_000_000),
            event(964_000, 1, "{}", 1_086_400),
            event(1_828_000, 1, "{}", 1_172_800),
        ]);
        let r = clock.resolve(1_828_000, 1_172_800);
        assert_eq!(r.source, ClockSource::Fallback);
        assert_eq!(r.unix, 1_172_800.0);
    }

    #[test]
    fn rebase_does_not_project_old_boot_offset_onto_new_boot() {
        // Old boot ran at high counts (anchored). A reboot restarts near zero and the
        // new boot has no anchor yet: its night must not be dated through the old
        // boot's clock (which would land it days earlier), nor to the download time.
        let clock = RingClock::from_events(&[
            event(
                5_000_000,
                0x42,
                r#"{"unix_time":1788800000}"#,
                1_788_800_000,
            ),
            event(5_100_000, 1, "{}", 1_788_800_000),
            event(10, 1, "{}", 1_789_056_420),
            event(300_000, 0x76, "{}", 1_789_056_420),
        ]);
        let r = clock.resolve(300_000, 1_789_056_420);
        assert_eq!(r.source, ClockSource::Undated);
        assert_ne!(
            r.unix,
            1_788_800_000.0 + (300_000 - 5_000_000) as f64 / 10.0
        );
    }

    #[test]
    fn phone_anchor_dates_new_boot() {
        // Same reboot, but the phone recorded an anchor at the end of the sync
        // (ring ds of the newest drained event ↔ phone time). 23:00→08:00 UTC+2.
        let sync_unix = 1_789_056_420; // 2026-09-11 ~ 09:27 UTC
        let clock = RingClock::from_events(&[
            event(
                5_000_000,
                0x42,
                r#"{"unix_time":1788800000}"#,
                1_788_800_000,
            ),
            event(10, 1, "{}", sync_unix),
            event(
                705_000,
                0x42,
                r#"{"unix_time":1789056420,"source":"phone"}"#,
                sync_unix,
            ),
        ]);
        // bed 22:59 UTC previous day → 06:00 UTC = 08:00 local
        let start = clock.resolve(705_000 - (sync_unix - 1_789_002_000) * 10, sync_unix);
        let end = clock.resolve(705_000 - (sync_unix - 1_789_020_000) * 10, sync_unix);
        assert_eq!(start.source, ClockSource::Anchor);
        assert_eq!(start.unix, 1_789_002_000.0);
        assert_eq!(end.unix, 1_789_020_000.0);
        let diag = clock.diagnostics();
        assert_eq!(diag["epochs"][1]["anchor_sources"][0], "phone");
    }

    #[test]
    fn audited_stalled_interval_with_hidden_and_decoded_reboots_marks_middle_ambiguous() {
        // Exact audited anchor bracket and reboot counters:
        // Anchor 1: ring_ds=47_893_458, unix_time=1_787_733_221
        // Reboot A (previously NULL decoded_json): 49_912_254
        // Reboot B (already decoded): 57_660_709
        // Anchor 2: ring_ds=61_076_535, unix_time=1_789_195_418
        // Wall time (406.166 h) exceeds counter time (366.197 h) by ~39.969 h.
        let cap = 1_789_195_500;
        let clock = RingClock::from_events(&[
            event(47_893_458, 0x42, r#"{"unix_time":1787733221}"#, 1_787_733_300),
            event(49_912_254, 0x41, r#"{"reason":4,"firmware_version":"2.1.20"}"#, cap),
            event(53_000_000, 0x76, "{}", cap),
            event(57_660_709, 0x41, r#"{"reason":4,"firmware_version":"2.1.20"}"#, cap),
            event(61_076_535, 0x42, r#"{"unix_time":1789195418}"#, cap),
        ]);

        // Before the first reboot (47_893_458..49_912_254): anchored to the earlier anchor.
        let before_first = clock.resolve(48_500_000, cap);
        assert_eq!(before_first.source, ClockSource::Anchor);
        assert!(before_first.undated_reason.is_none());

        // Between the two reboots (49_912_254..57_660_709): ambiguous multiple-reboot stall.
        let middle = clock.resolve(53_000_000, cap);
        assert_eq!(middle.source, ClockSource::Undated);
        assert_eq!(middle.undated_reason, Some(UndatedReason::AmbiguousRebootStall));
        assert_eq!(middle.undated_reason.unwrap().code(), "ambiguous_reboot_stall");
        assert!(!middle.undated_reason.unwrap().is_recoverable_by_sync(true));

        // After the second reboot (57_660_709..61_076_535): anchored to the later anchor.
        let after_second = clock.resolve(59_000_000, cap);
        assert_eq!(after_second.source, ClockSource::Anchor);
        assert!(after_second.undated_reason.is_none());
    }

    #[test]
    fn trusted_history_stats_ignores_erratic_counter_jump_undated_epochs_and_replays() {
        // Epoch 0: initial erratic epoch matching audited export (`min_ds=20700`,
        // `max_ds=184190173`, apparent raw span = 5115.8 h = 213.2 days), while wall
        // time between its anchors only advances 1 hour on July 3, 2026.
        // Epoch 1: 3 days of normal dated history (July 4–7, 2026) + a replayed copy.
        // Epoch 2: unanchored full-drain epoch spanning 50 hours of raw ds.
        let jul3 = 1_783_000_000_i64;
        let jul4 = 1_783_086_400_i64;
        let jul7 = jul4 + 3 * 86_400;
        let events = vec![
            // Epoch 0 (erratic counter jump: 20,700 -> 184,190,173 ds in 1 wall-clock hour)
            event(20_700, 0x42, &format!(r#"{{"unix_time":{jul3}}}"#), jul3),
            event(90_000_000, 1, "{}", jul3 + 1_800),
            event(
                184_190_173,
                0x42,
                &format!(r#"{{"unix_time":{}}}"#, jul3 + 3_600),
                jul3 + 3_600,
            ),
            // Epoch 1 (reboot to low ds, 3 days of trusted observations across 4 calendar days)
            event(10_000, 0x42, &format!(r#"{{"unix_time":{jul4}}}"#), jul4),
            event(10_000 + 864_000, 1, "{}", jul4 + 86_400),
            event(10_000 + 2 * 864_000, 1, "{}", jul4 + 2 * 86_400),
            event(10_000 + 3 * 864_000, 0x42, &format!(r#"{{"unix_time":{jul7}}}"#), jul7),
            // Replayed event from Epoch 1 captured later: must not double-count coverage.
            event(10_000 + 2 * 864_000, 1, "{}", jul7 + 3_600),
            // Epoch 2 (reboot to 100, unanchored full drain of 50 hours of ds)
            event(100, 1, "{}", jul7 + 7_200),
            event(1_800_100, 1, "{}", jul7 + 7_200),
        ];

        let clock = RingClock::from_events(&events);
        let stats = clock.trusted_history_stats(&events, 0.0);
        // True wall-clock span is jul3..jul7 = 4.0 days (NOT 213.2 + 3 + 2 = 218+ days!).
        assert_eq!(stats.elapsed_days, 4.0);
        assert_eq!(stats.observed_coverage_days, 4.0);
        assert!(stats.observed_days <= 5);

        // Verify undated reasons for the erratic middle event and the unanchored final epoch.
        let erratic = clock.resolve(90_000_000, jul3 + 1_800);
        assert_eq!(erratic.undated_reason, Some(UndatedReason::AcceleratedCounter));
        let unanchored = clock.resolve(1_800_100, jul7 + 7_200);
        assert_eq!(unanchored.undated_reason, Some(UndatedReason::MissingAnchor));
        assert!(clock.is_in_latest_unanchored_epoch(1_800_100, jul7 + 7_200));
    }
}
