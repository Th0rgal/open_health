//! Hourly heart-rate candles — the day-shaped view of HR the nightly RHR trend
//! cannot give.
//!
//! The ring never reports "heart rate" as a series: it reports beats. Two streams are
//! trustworthy enough to show a person:
//!
//! * `green_ibi_quality_event` (`0x80`) — only the pulse estimates the firmware's own
//!   quality gate accepted (`quality == 1`),
//! * `hrv_event` — the firmware's `interval_min`-minute averages.
//!
//! `ibi_and_amplitude_event` (`0x60`) is deliberately NOT used. It is the raw
//! beat-to-beat stream with no quality flag, and on this Gen 3 (fw 3.4.3) 13% of its
//! beats land above 100 bpm during sleep, topping out at 176 — the bit layout was
//! ported from a Ring 5 native parser and has never been validated here. Measured over
//! a real night it added nothing: `green_ibi_quality` already covered every hour it
//! appeared in. `build_summary` distrusts the same stream for the same reason.
//!
//! Even a quality-gated beat stream has the odd bad estimate, so an hour's band is the
//! 5th–95th percentile of its beats, not the raw extremes — one misdetected beat must
//! not become "your peak heart rate". True `min`/`max` ride along for the detail
//! readout. Percentiles come from a per-hour histogram, so memory stays flat no matter
//! how many beats an hour holds.
//!
//! Grouping those into local-clock hours gives one bar per hour: the lowest and
//! highest beat actually measured, and the mean of every beat in between. There is no
//! open/close — a heart rate is not a share price, and "the first beat of the hour"
//! carries no information the range and the mean do not. Only `hrv_event` carries
//! per-sample spacing (`interval_min`), so its samples are placed at `ds + i·interval`;
//! the beat streams have no per-sample timestamps and sit at their event's time, which
//! is honest — an event covers seconds, not hours.
//!
//! `latest` deliberately mirrors `build_summary`'s `vitals.hr`: the newest
//! quality-gated green-LED estimate, so the number on the detail screen is the same
//! number as the dashboard cell.

use std::collections::BTreeMap;
use std::path::Path;

use anyhow::{Context, Result};
use serde_json::{json, Value};

use crate::ring_time::RingClock;
use oura_store::storage::Store;

/// Physiologically plausible range for a wrist/finger PPG beat estimate. The same
/// gate the decoders and `build_summary` apply, kept here so a garbage IBI can never
/// stretch a candle.
const MIN_BPM: f64 = 30.0;
const MAX_BPM: f64 = 240.0;

const HOUR: i64 = 3600;

/// One bin per whole bpm from 0 to [`MAX_BPM`], so an hour costs a fixed ~1 KB
/// whether it holds ten beats or ten thousand.
const BINS: usize = MAX_BPM as usize + 1;

struct Bar {
    hist: Vec<u32>,
    min: f64,
    max: f64,
    count: u64,
    /// How many of `count` are `hrv_event` averages rather than beats.
    averages: u64,
}

impl Default for Bar {
    fn default() -> Self {
        Bar {
            hist: vec![0; BINS],
            min: f64::MAX,
            max: f64::MIN,
            count: 0,
            averages: 0,
        }
    }
}

impl Bar {
    fn add(&mut self, bpm: f64) {
        self.min = self.min.min(bpm);
        self.max = self.max.max(bpm);
        self.hist[(bpm.round() as usize).min(BINS - 1)] += 1;
        self.count += 1;
    }

    /// Nearest-rank percentile over the histogram (`p` in 0..=100).
    fn percentile(&self, p: f64) -> f64 {
        let rank = ((p / 100.0) * self.count as f64).ceil().max(1.0) as u64;
        let mut seen = 0u64;
        for (bpm, n) in self.hist.iter().enumerate() {
            seen += *n as u64;
            if seen >= rank {
                return bpm as f64;
            }
        }
        self.max
    }
}

/// One bar per local-clock hour that actually has beats, oldest first.
///
/// `tz` is whole hours from UTC (the same offset `build_summary` takes), `days` caps
/// the window to that many days back from the newest sample — 0 means everything.
///
/// ```text
/// { "tz_offset": 3, "minutes": 60,
///   "hours": [ { "unix": 1757714400, "ymd": "2026-09-12", "hour": 21, "minute": 0,
///                "low": 48, "high": 71, "median": 54, "min": 46, "max": 96,
///                "count": 812, "beats": 800, "averages": 12 } ],
///   "latest": { "bpm": 61, "unix": 1757800000 } }
/// ```
/// `low`/`high` are the 5th/95th percentiles — the band the hour actually lived in.
/// This is [`hr_bins`] at 60 minutes under the `hours` key the iOS app reads.
pub fn hourly_hr(db: &Path, tz: i64, days: u32) -> Result<Value> {
    let mut v = hr_bins(db, tz, days, 60)?;
    let bins = v
        .as_object_mut()
        .and_then(|o| o.remove("bins"))
        .unwrap_or_else(|| json!([]));
    v["hours"] = bins;
    Ok(v)
}

/// Heart-rate bars per local-clock slot of `minutes`, oldest first, under `bins`.
///
/// `minutes` must divide 60, so slots line up with the hour on the wearer's clock.
/// Rows are the hourly rows plus `minute` (the slot's start within its hour). Finer
/// slots hold fewer values, and at night the only source is `hrv_event`'s 5-minute
/// averages — three per quarter hour — so each row splits `count` into `beats` and
/// `averages` for the chart to say what a bar is made of.
pub fn hr_bins(db: &Path, tz: i64, days: u32, minutes: u32) -> Result<Value> {
    if minutes == 0 || 60 % minutes != 0 {
        anyhow::bail!("bin size must divide an hour, got {minutes} minutes");
    }
    let span = minutes as i64 * 60;
    let store = Store::open_read_only(db).context("opening DB")?;
    let events = store.decoded_events().context("reading events")?;
    if events.is_empty() {
        return Ok(json!({ "tz_offset": tz, "minutes": minutes, "bins": [], "latest": Value::Null }));
    }
    let clock = RingClock::from_events(&events);

    let mut bins: BTreeMap<i64, Bar> = BTreeMap::new();
    let mut latest: Option<(f64, f64)> = None; // (unix, bpm)

    for (ds, tag, jstr, cu) in &events {
        let name = oura_protocol::events::event_name(*tag);
        if !matches!(name, "green_ibi_quality_event" | "hrv_event") {
            continue;
        }
        let Ok(v) = serde_json::from_str::<Value>(jstr) else {
            continue;
        };
        let Some(bpms) = v["hr_bpm"].as_array() else {
            continue;
        };
        // hrv_event packs `interval_min`-minute averages; element i is that much later.
        let step_ds = if name == "hrv_event" {
            v["interval_min"].as_i64().unwrap_or(5).max(1) * 600
        } else {
            0
        };
        for (i, x) in bpms.iter().enumerate() {
            let Some(bpm) = x.as_f64() else { continue };
            if !(MIN_BPM..=MAX_BPM).contains(&bpm) {
                continue;
            }
            let at = clock.unix_s(*ds + i as i64 * step_ds, *cu);
            let bar = bins.entry(bucket_start(at, tz, span)).or_default();
            bar.add(bpm);
            if name == "hrv_event" {
                bar.averages += 1;
            }
            if name == "green_ibi_quality_event"
                && latest.map_or(true, |(current, _)| at > current)
            {
                latest = Some((at, bpm));
            }
        }
    }

    if days > 0 {
        if let Some(newest) = bins.keys().next_back().copied() {
            let cut = newest - days as i64 * 86_400;
            bins.retain(|start, _| *start >= cut);
        }
    }

    let out: Vec<Value> = bins
        .iter()
        .map(|(start, bar)| {
            let (ymd, hour) = local_ymd_hour(*start, tz);
            json!({
                "unix": start,
                "ymd": ymd,
                "hour": hour,
                "minute": (start + tz * HOUR).rem_euclid(HOUR) / 60,
                "low": bar.percentile(5.0),
                "high": bar.percentile(95.0),
                "median": bar.percentile(50.0),
                "min": bar.min,
                "max": bar.max,
                "count": bar.count,
                "beats": bar.count - bar.averages,
                "averages": bar.averages,
            })
        })
        .collect();

    Ok(json!({
        "tz_offset": tz,
        "minutes": minutes,
        "bins": out,
        "latest": latest.map(|(at, bpm)| json!({ "bpm": bpm, "unix": at.round() as i64 })),
    }))
}

/// UTC start of the local-clock slot of `span` seconds (a divisor of an hour) a
/// sample falls in. Bucketing in local time is what makes "3 am" mean 3 am on the
/// wearer's wall clock; the key stays UTC so the chart's x-axis needs no second
/// conversion.
fn bucket_start(unix: f64, tz: i64, span: i64) -> i64 {
    let local = unix + (tz * HOUR) as f64;
    (local / span as f64).floor() as i64 * span - tz * HOUR
}

/// `(YYYY-MM-DD, hour)` of a bucket start, in the wearer's local clock. Civil-date
/// arithmetic from days-since-epoch (Howard Hinnant's algorithm) — no chrono in the
/// dependency set, and the whole stack works in whole-hour offsets anyway.
fn local_ymd_hour(bucket_start_unix: i64, tz: i64) -> (String, i64) {
    let local = bucket_start_unix + tz * HOUR;
    let days = local.div_euclid(86_400);
    let hour = local.rem_euclid(86_400) / HOUR;
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z.rem_euclid(146_097);
    let yoe = (doe - doe / 1_460 + doe / 36_524 - doe / 146_096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    let y = if m <= 2 { y + 1 } else { y };
    (format!("{y:04}-{m:02}-{d:02}"), hour)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn civil_date_matches_known_instants() {
        // 2026-09-13T00:00:00Z = 1789257600; at tz=+3 that is 03:00 local the same day.
        assert_eq!(
            local_ymd_hour(1_789_257_600, 3),
            ("2026-09-13".to_string(), 3)
        );
        // epoch itself, and a pre-epoch instant (negative days must not panic).
        assert_eq!(local_ymd_hour(0, 0), ("1970-01-01".to_string(), 0));
        assert_eq!(local_ymd_hour(-86_400, 0), ("1969-12-31".to_string(), 0));
    }

    #[test]
    fn buckets_floor_to_the_local_hour() {
        let tz = 3;
        let start = bucket_start(1_789_257_600.0 + 1_900.0, tz, HOUR);
        assert_eq!(start, 1_789_257_600);
        assert_eq!(bucket_start(1_789_257_600.0 + 3_601.0, tz, HOUR), 1_789_261_200);
        // a sample before the epoch must floor down, not toward zero
        assert_eq!(bucket_start(-1.0, 0, HOUR), -3600);
    }

    #[test]
    fn percentile_band_ignores_a_lone_bad_beat() {
        let mut bar = Bar::default();
        for _ in 0..99 {
            bar.add(60.0);
        }
        bar.add(176.0); // one misdetected beat, exactly what the raw IBI stream emits
        assert_eq!(bar.max, 176.0, "the outlier is still recorded");
        assert_eq!(bar.percentile(95.0), 60.0, "but it must not become the band top");
        assert_eq!(bar.percentile(50.0), 60.0);
        assert_eq!(bar.count, 100);
    }

    #[test]
    fn percentiles_split_a_known_spread() {
        let mut bar = Bar::default();
        for bpm in 1..=100 {
            bar.add(bpm as f64);
        }
        assert_eq!(bar.percentile(5.0), 5.0);
        assert_eq!(bar.percentile(50.0), 50.0);
        assert_eq!(bar.percentile(95.0), 95.0);
        assert_eq!(bar.min, 1.0);
        assert_eq!(bar.max, 100.0);
    }

    /// End to end over a real store: three sources, three hours, one bar each.
    #[test]
    fn groups_beats_into_local_hours() {
        use oura_protocol::events::RingEvent;

        let dir = std::env::temp_dir().join(format!("oura-hourly-hr-e2e-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let db = dir.join("oura.db");
        let _ = std::fs::remove_file(&db);

        // Anchor in the recent past: the clock refuses projections far beyond the
        // capture time, and insert_event stamps captured_unix as "now".
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_secs() as i64;
        let anchor = (now - 6 * HOUR) / HOUR * HOUR;

        {
            let store = Store::open(db.to_str().unwrap()).unwrap();
            let push = |tag: u8, name: &'static str, ds: i64, decoded: Value| {
                store
                    .insert_event(
                        "S1",
                        &RingEvent {
                            tag,
                            name,
                            timestamp: ds as u32,
                            body: vec![0],
                            decoded: Some(decoded),
                        },
                    )
                    .unwrap();
            };
            push(0x42, "time_sync", 0, json!({ "unix_time": anchor }));
            // +1 h: two daytime beats in one event
            push(
                0x80,
                "green_ibi_quality_event",
                36_000,
                json!({ "hr_bpm": [60, 70] }),
            );
            // +2 h: one beat, and an implausible value the gate must drop
            push(
                0x80,
                "green_ibi_quality_event",
                72_000,
                json!({ "hr_bpm": [50, 500] }),
            );
            // +3 h: firmware 5-minute averages — both land in the same hour
            push(
                0x5d,
                "hrv_event",
                108_000,
                json!({ "interval_min": 5, "hr_bpm": [40, 45] }),
            );
            // +3 h: raw beat-to-beat, deliberately ignored — a 170 bpm "beat" during
            // sleep is what this stream produces and what must never reach the chart
            push(
                0x60,
                "ibi_and_amplitude_event",
                108_100,
                json!({ "hr_bpm": [170, 172] }),
            );
        }

        let v = hourly_hr(&db, 0, 0).unwrap();
        let hours = v["hours"].as_array().unwrap();
        assert_eq!(hours.len(), 3, "{v}");
        assert_eq!(hours[0]["min"], 60.0);
        assert_eq!(hours[0]["max"], 70.0);
        assert_eq!(hours[0]["count"], 2);
        assert_eq!(hours[1]["min"], 50.0, "500 bpm must be gated out: {v}");
        assert_eq!(hours[1]["max"], 50.0);
        assert_eq!(hours[2]["min"], 40.0);
        assert_eq!(
            hours[2]["max"], 45.0,
            "raw ibi_and_amplitude beats must not reach the chart: {v}"
        );
        assert_eq!(hours[2]["count"], 2);
        // consecutive hours, one slot apart
        let starts: Vec<i64> = hours.iter().map(|h| h["unix"].as_i64().unwrap()).collect();
        assert_eq!(starts[1] - starts[0], HOUR);
        assert_eq!(starts[2] - starts[1], HOUR);
        // `latest` mirrors the dashboard cell: newest green-LED estimate only
        assert_eq!(v["latest"]["bpm"], 50.0, "{v}");

        let _ = std::fs::remove_file(&db);
    }

    #[test]
    fn buckets_floor_to_the_local_quarter_hour() {
        let tz = 3;
        let hour = 1_789_257_600.0; // a local-hour boundary at tz=+3
        assert_eq!(bucket_start(hour + 899.0, tz, 900), 1_789_257_600);
        assert_eq!(bucket_start(hour + 900.0, tz, 900), 1_789_257_600 + 900);
        assert_eq!(bucket_start(hour + 1_900.0, tz, 900), 1_789_257_600 + 1_800);
    }

    #[test]
    fn rejects_bin_sizes_that_do_not_divide_an_hour() {
        // checked before the DB is touched, so a missing path is fine here
        let missing = Path::new("/nonexistent/oura.db");
        assert!(hr_bins(missing, 0, 0, 7).is_err());
        assert!(hr_bins(missing, 0, 0, 0).is_err());
        assert!(hr_bins(missing, 0, 0, 90).is_err());
    }

    /// 15-minute slots over a real store: beats split by quarter hour, and a slot
    /// built only from the firmware's 5-minute averages says so.
    #[test]
    fn groups_into_quarter_hours_and_counts_averages() {
        use oura_protocol::events::RingEvent;

        let dir = std::env::temp_dir().join(format!("oura-hr-bins-e2e-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let db = dir.join("oura.db");
        let _ = std::fs::remove_file(&db);

        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_secs() as i64;
        let anchor = (now - 6 * HOUR) / HOUR * HOUR;

        {
            let store = Store::open(db.to_str().unwrap()).unwrap();
            let push = |tag: u8, name: &'static str, ds: i64, decoded: Value| {
                store
                    .insert_event(
                        "S1",
                        &RingEvent {
                            tag,
                            name,
                            timestamp: ds as u32,
                            body: vec![0],
                            decoded: Some(decoded),
                        },
                    )
                    .unwrap();
            };
            push(0x42, "time_sync", 0, json!({ "unix_time": anchor }));
            // +1:00 two beats, +1:15 one beat (deciseconds: 15 min = 9 000)
            push(0x80, "green_ibi_quality_event", 36_000, json!({ "hr_bpm": [60, 70] }));
            push(0x80, "green_ibi_quality_event", 45_000, json!({ "hr_bpm": [80] }));
            // +3:00, +3:05, +3:10: three 5-minute averages, all in the 3:00 slot
            push(
                0x5d,
                "hrv_event",
                108_000,
                json!({ "interval_min": 5, "hr_bpm": [40, 45, 50] }),
            );
        }

        let v = hr_bins(&db, 0, 0, 15).unwrap();
        assert_eq!(v["minutes"], 15);
        let bins = v["bins"].as_array().unwrap();
        assert_eq!(bins.len(), 3, "{v}");
        assert_eq!((bins[0]["minute"].as_i64(), bins[1]["minute"].as_i64()), (Some(0), Some(15)));
        assert_eq!(bins[1]["unix"].as_i64().unwrap() - bins[0]["unix"].as_i64().unwrap(), 900);
        assert_eq!((bins[0]["beats"].as_u64(), bins[0]["averages"].as_u64()), (Some(2), Some(0)));
        assert_eq!(bins[1]["beats"], 1);
        assert_eq!((bins[2]["beats"].as_u64(), bins[2]["averages"].as_u64()), (Some(0), Some(3)));
        assert_eq!((bins[2]["min"].as_f64(), bins[2]["max"].as_f64()), (Some(40.0), Some(50.0)));
        assert_eq!(bins[2]["count"], 3);

        // the hourly contract the iOS app reads is unchanged: same data, `hours` key
        let h = hourly_hr(&db, 0, 0).unwrap();
        assert_eq!(h["hours"].as_array().unwrap().len(), 2, "{h}");
        assert!(h.get("bins").is_none());

        let _ = std::fs::remove_file(&db);
    }

    #[test]
    fn empty_database_yields_no_hours() {
        let dir = std::env::temp_dir().join(format!("oura-hourly-hr-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let db = dir.join("oura.db");
        let _ = std::fs::remove_file(&db);
        drop(Store::open(db.to_str().unwrap()).unwrap());
        let v = hourly_hr(&db, 0, 7).unwrap();
        assert_eq!(v["hours"].as_array().unwrap().len(), 0);
        assert!(v["latest"].is_null());
        let _ = std::fs::remove_file(&db);
    }
}
