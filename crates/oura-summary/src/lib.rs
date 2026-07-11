//! The dashboard **summary computation** — the single source of truth both clients
//! render. Moved verbatim out of `oura-cli/src/dashboard.rs` so the native (iOS)
//! client computes the *same* JSON as the web client; the only thing the two share
//! is this crate, so they can't drift.
//!
//! The ML models (sleep hypnogram, cardiovascular age, activity sessions) are an
//! injected [`ModelRunner`]: `oura-cli` shells out to the Python torch runners, the
//! native client runs the `.ptl` models on-device (or supplies [`NoModelRunner`]).
//! Everything else here is pure Rust over the synced SQLite DB.
//!
//! A new field added to the JSON here surfaces in BOTH clients — but each must still
//! *render* it: web `dashboard/web/app.js`, iOS `apps/ios/OuraApp/OuraApp.swift`. See
//! `docs/clients-web-and-ios.md`.

mod ring_time;

use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

use anyhow::{anyhow, Context, Result};
use serde_json::{json, Value};

use oura_store::storage::Store;
use ring_time::RingClock;

/// User anthropometrics — only the CVA model needs them; everything else is
/// signal-derived. Stored in an editable `profile.json` next to the DB.
#[derive(Clone, Copy)]
pub struct Demographics {
    pub sex: char, // 'M' | 'F' | 'O'
    pub age: f64,
    pub height_m: f64,
    pub weight_kg: f64,
    pub ring_size: f64,
}

impl Demographics {
    pub fn to_json(self) -> Value {
        json!({ "sex": self.sex.to_string(), "age": self.age, "height_m": self.height_m,
                "weight_kg": self.weight_kg, "ring_size": self.ring_size })
    }
    pub fn from_json(v: &Value) -> Self {
        let d = Demographics::default();
        Demographics {
            sex: v["sex"]
                .as_str()
                .and_then(|s| s.chars().next())
                .unwrap_or(d.sex)
                .to_ascii_uppercase(),
            age: v["age"].as_f64().unwrap_or(d.age),
            height_m: v["height_m"].as_f64().unwrap_or(d.height_m),
            weight_kg: v["weight_kg"].as_f64().unwrap_or(d.weight_kg),
            ring_size: v["ring_size"].as_f64().unwrap_or(d.ring_size),
        }
    }
}
impl Default for Demographics {
    fn default() -> Self {
        Demographics {
            sex: 'M',
            age: 30.0,
            height_m: 1.78,
            weight_kg: 75.0,
            ring_size: 10.0,
        }
    }
}

// ── the model seam ────────────────────────────────────────────────────────────
/// What the ML models need: the DB, timezone, profile, and the night windows to
/// stage. The runner returns each model's raw `--json` output (or `None`).
pub struct ModelInputs<'a> {
    pub db: &'a Path,
    pub tz: i64,
    pub demo: &'a Demographics,
    pub sleep_ranges: &'a [[i64; 2]],
}

/// Raw model outputs, matching the Python runners' `--json` shape.
#[derive(Default)]
pub struct ModelOutputs {
    pub sleep_batch: Option<Value>, // run_sleep_model.py --batch
    pub cva: Option<Value>,         // run_cva_model.py
    pub activity: Option<Value>,    // run_activity_model.py
}

/// Runs the torch models. `oura-cli` shells out to Python; the native client runs
/// `.ptl` on-device. [`NoModelRunner`] degrades to the signal-derived panels only.
pub trait ModelRunner {
    fn run(&self, input: ModelInputs) -> ModelOutputs;
}

/// No models — vitals / cardio-trend / activity-profile / device / digest only.
pub struct NoModelRunner;
impl ModelRunner for NoModelRunner {
    fn run(&self, _: ModelInputs) -> ModelOutputs {
        ModelOutputs::default()
    }
}

// ── profile + feature-mode persistence (files next to the DB) ─────────────────
pub fn profile_path(db: &Path) -> PathBuf {
    db.parent().unwrap_or(Path::new(".")).join("profile.json")
}
/// Read the user profile (defaults if absent or malformed).
pub fn read_profile(db: &Path) -> Demographics {
    std::fs::read_to_string(profile_path(db))
        .ok()
        .and_then(|s| serde_json::from_str::<Value>(&s).ok())
        .map(|v| Demographics::from_json(&v))
        .unwrap_or_default()
}
pub fn write_profile(db: &Path, v: &Value) -> Result<Demographics> {
    let demo = Demographics::from_json(v);
    std::fs::write(
        profile_path(db),
        serde_json::to_vec_pretty(&demo.to_json())?,
    )
    .context("writing profile.json")?;
    Ok(demo)
}

pub fn feature_modes_path(db: &Path) -> PathBuf {
    db.parent()
        .unwrap_or(Path::new("."))
        .join("feature_modes.json")
}
/// Real on-ring feature modes snapshotted at the last sync, as `{ feature: mode }`.
pub fn read_feature_modes(db: &Path) -> Value {
    std::fs::read_to_string(feature_modes_path(db))
        .ok()
        .and_then(|s| serde_json::from_str::<Value>(&s).ok())
        .unwrap_or(Value::Null)
}
/// Persist a snapshot of on-ring feature modes as `{ feature: mode, …, _at: unix_secs }`.
/// Stamps `_at` and writes atomically next to the DB; best-effort (never panics/errs).
pub fn write_feature_modes(db: &Path, mut modes: serde_json::Map<String, Value>) {
    let at = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    modes.insert("_at".into(), json!(at));
    let _ = std::fs::write(
        feature_modes_path(db),
        serde_json::to_vec_pretty(&Value::Object(modes)).unwrap_or_default(),
    );
}
/// Record a feature's new mode (0 = off, 1 = automatic) right after a toggle.
pub fn write_feature_mode(db: &Path, feature: &str, mode_int: i64) {
    let mut modes = match read_feature_modes(db) {
        Value::Object(m) => m,
        _ => serde_json::Map::new(),
    };
    modes.insert(feature.to_string(), json!(mode_int));
    write_feature_modes(db, modes);
}

// ── small date helpers (no chrono dep) ────────────────────────────────────────
/// Howard Hinnant's civil_from_days: days since 1970-01-01 → (year, month, day).
pub fn civil(days: i64) -> (i64, u32, u32) {
    let z = days + 719468;
    let era = (if z >= 0 { z } else { z - 146096 }) / 146097;
    let doe = z - era * 146097;
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = (doy - (153 * mp + 2) / 5 + 1) as u32;
    let m = (if mp < 10 { mp + 3 } else { mp - 9 }) as u32;
    (y + i64::from(m <= 2), m, d)
}
/// Inverse of `civil`: (year, month, day) → days since 1970-01-01.
pub fn days_from_civil(y: i64, m: u32, d: u32) -> i64 {
    let y = if m <= 2 { y - 1 } else { y };
    let era = (if y >= 0 { y } else { y - 399 }) / 400;
    let yoe = y - era * 400;
    let m = m as i64;
    let doy = (153 * (if m > 2 { m - 3 } else { m + 9 }) + 2) / 5 + d as i64 - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    era * 146097 + doe - 719468
}

const WD: [&str; 7] = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"];

fn date_label(unix_s: f64, tz: i64) -> String {
    let days = (unix_s as i64 + tz * 3600).div_euclid(86400);
    let (_, m, d) = civil(days);
    let wd = WD[(days + 3).rem_euclid(7) as usize];
    format!("{wd} {m:02}-{d:02}")
}
/// Full calendar date (`YYYY-MM-DD`) — an unambiguous key for matching a night to a
/// day's activity (the weekday `date_label` collides across years).
fn ymd_label(unix_s: f64, tz: i64) -> String {
    let days = (unix_s as i64 + tz * 3600).div_euclid(86400);
    let (y, m, d) = civil(days);
    format!("{y:04}-{m:02}-{d:02}")
}

const SLEEP_DEBT_DAYS: i64 = 14;
const SLEEP_NEED_H: f64 = 8.0;

/// Android's sleep-debt screen works on calendar days, not individual sleep sessions:
/// a main sleep and a nap ending on the same day both contribute to that day's total.
/// Build the complete 14-day series here so every client renders the same result.
fn sleep_debt_summary(asleep_by_day: &std::collections::BTreeMap<i64, i32>) -> Value {
    use oura_analysis::ported::sleep_debt::{sleep_debt, SleepDebtConfig};

    let Some(&anchor) = asleep_by_day.keys().next_back() else {
        return json!({
            "debt_min": 0, "recent_shortfall_min": 0, "valid": false,
            "need_h": SLEEP_NEED_H, "valid_days": 0, "window_days": SLEEP_DEBT_DAYS,
            "state": "none", "days": [],
        });
    };
    let need_s = (SLEEP_NEED_H * 3600.0) as i32;
    let first = anchor - (SLEEP_DEBT_DAYS - 1);
    let mut days = Vec::with_capacity(SLEEP_DEBT_DAYS as usize);

    for day in first..=anchor {
        let window_first = day - (SLEEP_DEBT_DAYS - 1);
        let actual: Vec<i32> = (window_first..=day)
            .rev()
            .map(|d| asleep_by_day.get(&d).copied().unwrap_or(0))
            .collect();
        let need = vec![need_s; actual.len()];
        let debt = sleep_debt(&actual, &need, &SleepDebtConfig::default());
        let total = asleep_by_day.get(&day).copied();
        let valid_days = actual.iter().filter(|&&s| s > 0).count();
        let (y, m, d) = civil(day);
        days.push(json!({
            "date": format!("{y:04}-{m:02}-{d:02}"),
            "total_sleep_min": total.map(|s| (s as f64 / 60.0).round()),
            "sleep_need_min": SLEEP_NEED_H * 60.0,
            "shortfall_min": total.map(|s| ((need_s - s) as f64 / 60.0).round()),
            "cumulative_debt_min": debt.valid.then(|| (debt.debt_s as f64 / 60.0).round()),
            "valid_days": valid_days,
        }));
    }

    let actual: Vec<i32> = (first..=anchor)
        .rev()
        .map(|d| asleep_by_day.get(&d).copied().unwrap_or(0))
        .collect();
    let valid_days = actual.iter().filter(|&&s| s > 0).count();
    let need = vec![need_s; actual.len()];
    let debt = sleep_debt(&actual, &need, &SleepDebtConfig::default());
    let debt_min = if debt.valid {
        (debt.debt_s as f64 / 60.0).round()
    } else {
        0.0
    };
    let state = match debt_min {
        d if d >= 540.0 => "high",
        d if d >= 360.0 => "moderate",
        d if d >= 180.0 => "low",
        _ => "none",
    };
    let recent_shortfall_min = if debt.valid && debt.recent_shortfall_s != i32::MAX {
        (debt.recent_shortfall_s as f64 / 60.0).round()
    } else {
        0.0
    };
    json!({
        "debt_min": debt_min,
        "recent_shortfall_min": recent_shortfall_min,
        "valid": debt.valid,
        "need_h": SLEEP_NEED_H,
        "valid_days": valid_days,
        "window_days": SLEEP_DEBT_DAYS,
        "state": state,
        "days": days,
    })
}
fn hm(unix_s: f64, tz: i64) -> String {
    let sod = (unix_s as i64 + tz * 3600).rem_euclid(86400);
    format!("{:02}:{:02}", sod / 3600, (sod % 3600) / 60)
}
/// Oura "SpO2 Simple" calibration → percent, clamped to the 85–100 display range.
/// The quadratic itself is ecore's `spo2_simple_calculate` (see `oura_analysis`);
/// these are the gen4/oreo coefficients (`a + b·r + c·r²`).
fn spo2_pct(r: f64) -> f64 {
    oura_analysis::ported::spo2::spo2_simple(r, 105.2, -5.1, -13.4).clamp(85.0, 100.0)
}

fn mean(v: &[f64]) -> Option<f64> {
    (!v.is_empty()).then(|| v.iter().sum::<f64>() / v.len() as f64)
}

/// Nightly skin temperature (°C) via ecore's `nightly_temperature` (7-sample median
/// → 30-sample windows → minimum of the window maxima). Falls back to the plain mean
/// when there aren't enough valid windows, so sparse nights still report a value.
fn nightly_skin_temp(temps_c: &[f64]) -> Option<f64> {
    let centi: Vec<u16> = temps_c
        .iter()
        .map(|&c| (c * 100.0).round().clamp(0.0, u16::MAX as f64) as u16)
        .collect();
    oura_analysis::ported::temperature::nightly_temperature(&centi)
        .map(|t| t as f64 / 100.0)
        .or_else(|| mean(temps_c))
}

// ── per-night signal accumulation ────────────────────────────────────────────
#[derive(Default)]
struct Night {
    start_ds: i64,
    end_ds: i64,
    raw_start_ds: i64,
    raw_end_ds: i64,
    captured_unix: i64,
    rmssd: Vec<f64>,
    hr: Vec<f64>,
    temp: Vec<f64>,
    temp_start_ds: Option<i64>,
    temp_end_ds: Option<i64>,
    spo2: Vec<f64>,
    motion: Vec<f64>,
    // timestamped (time_ds, value) HRV/HR samples for stage-resolved autonomics — the
    // flat `rmssd`/`hr` vecs above drop timing, which we need to map each sample to its
    // hypnogram stage.
    hrv_t: Vec<(i64, f64)>,
    hr_t: Vec<(i64, f64)>,
}

#[derive(Clone, Copy, Debug, PartialEq)]
struct BedPeriod {
    start_ds: i64,
    end_ds: i64,
    raw_start_ds: i64,
    raw_end_ds: i64,
    captured_unix: i64,
}

const MAX_BED_BREAK_DS: i64 = 60 * 60 * 10;
const MAX_SLEEP_SIGNAL_EXTENSION_DS: i64 = 3 * 60 * 60 * 10;
const EPOCH_ALIGNMENT_SLACK_S: f64 = 5.0 * 60.0;
const PULSE_BURST_GAP_DS: i64 = 2 * 60 * 10;
const MAX_PULSE_CONTINUATION_GAP_DS: i64 = 15 * 60 * 10;
const MIN_ACCEPTED_BEATS_PER_BURST: usize = 2;
const MIN_LONG_SLEEP_DS: i64 = 3 * 60 * 60 * 10;
const MIN_PREMATURE_END_EVIDENCE_DS: i64 = 30 * 60 * 10;

/// Return the end of a continuous sequence of pulse-measurement bursts after the
/// explicit sleep sensors stop. Ring 5 may briefly leave sleep mode after an awakening
/// while still recording good PPG/IBI every ~10 minutes. A lone daytime HR sample is
/// not enough evidence: each accepted burst needs multiple packets and every burst must
/// remain close to the preceding accepted sleep evidence.
fn pulse_continuation_end(
    raw_end_ds: i64,
    explicit_end_ds: i64,
    captured_unix: i64,
    pulse_support: &[(i64, i64, usize)],
    unix_s_at: impl Fn(i64, i64) -> f64 + Copy,
) -> i64 {
    let raw_end_unix = unix_s_at(raw_end_ds, captured_unix);
    let max_end_ds = raw_end_ds + MAX_SLEEP_SIGNAL_EXTENSION_DS;
    let mut candidates: Vec<(i64, i64, usize)> = pulse_support
        .iter()
        .copied()
        .filter(|&(ds, cu, _)| {
            if ds < explicit_end_ds || ds > max_end_ds {
                return false;
            }
            let raw_elapsed = (ds - raw_end_ds) as f64 / 10.0;
            (unix_s_at(ds, cu) - raw_end_unix - raw_elapsed).abs() <= EPOCH_ALIGNMENT_SLACK_S
        })
        .collect();
    candidates.sort_by_key(|&(ds, _, _)| ds);

    let mut bursts: Vec<Vec<(i64, i64, usize)>> = Vec::new();
    for point in candidates {
        let continues =
            bursts
                .last()
                .and_then(|b| b.last())
                .is_some_and(|&(last_ds, last_cu, _)| {
                    let raw_gap = point.0 - last_ds;
                    let wall_gap = unix_s_at(point.0, point.1) - unix_s_at(last_ds, last_cu);
                    (0..=PULSE_BURST_GAP_DS).contains(&raw_gap)
                        && (0.0..=PULSE_BURST_GAP_DS as f64 / 10.0).contains(&wall_gap)
                });
        if continues {
            bursts.last_mut().expect("burst exists").push(point);
        } else {
            bursts.push(vec![point]);
        }
    }

    let mut accepted_end = explicit_end_ds;
    let mut accepted_cu = captured_unix;
    for burst in bursts
        .into_iter()
        .filter(|b| b.iter().map(|point| point.2).sum::<usize>() >= MIN_ACCEPTED_BEATS_PER_BURST)
    {
        let first = burst[0];
        let raw_gap = first.0 - accepted_end;
        let wall_gap = unix_s_at(first.0, first.1) - unix_s_at(accepted_end, accepted_cu);
        if raw_gap > MAX_PULSE_CONTINUATION_GAP_DS
            || wall_gap > MAX_PULSE_CONTINUATION_GAP_DS as f64 / 10.0
        {
            break;
        }
        if raw_gap >= -PULSE_BURST_GAP_DS && wall_gap >= -(PULSE_BURST_GAP_DS as f64 / 10.0) {
            if let Some(&(ds, cu, _)) = burst.last() {
                accepted_end = accepted_end.max(ds);
                accepted_cu = cu;
            }
        }
    }
    accepted_end
}

/// Turn the ring's raw bedtime markers into user-facing sleep windows.
///
/// A short wake can produce two adjacent `bedtime_period` records, and an early
/// marker can be followed by hours of sleep-only sensor packets. SleepNet cannot
/// recover either case because bedtime is an input boundary, so normalize that
/// boundary before both the summary and model runners consume it.
fn normalize_bed_periods(
    mut periods: Vec<BedPeriod>,
    sleep_support: &[(i64, i64)],
    pulse_support: &[(i64, i64, usize)],
    unix_s_at: impl Fn(i64, i64) -> f64 + Copy,
) -> Vec<BedPeriod> {
    periods.sort_by(|a, b| {
        unix_s_at(a.start_ds, a.captured_unix).total_cmp(&unix_s_at(b.start_ds, b.captured_unix))
    });

    let merge_adjacent = |periods: Vec<BedPeriod>| {
        let mut merged: Vec<BedPeriod> = Vec::new();
        for period in periods {
            let Some(previous) = merged.last_mut() else {
                merged.push(period);
                continue;
            };
            let raw_gap_ds = period.start_ds - previous.end_ds;
            let wall_gap_s = unix_s_at(period.start_ds, period.captured_unix)
                - unix_s_at(previous.end_ds, previous.captured_unix);
            let same_epoch =
                (wall_gap_s - raw_gap_ds as f64 / 10.0).abs() <= EPOCH_ALIGNMENT_SLACK_S;
            if same_epoch
                && raw_gap_ds <= MAX_BED_BREAK_DS
                && wall_gap_s <= MAX_BED_BREAK_DS as f64 / 10.0
                && raw_gap_ds >= -MAX_SLEEP_SIGNAL_EXTENSION_DS
                && wall_gap_s >= -(MAX_SLEEP_SIGNAL_EXTENSION_DS as f64 / 10.0)
            {
                previous.end_ds = previous.end_ds.max(period.end_ds);
                previous.raw_start_ds = previous.raw_start_ds.min(period.raw_start_ds);
                previous.raw_end_ds = previous.raw_end_ds.max(period.raw_end_ds);
                previous.captured_unix = previous.captured_unix.max(period.captured_unix);
            } else {
                merged.push(period);
            }
        }
        merged
    };

    let mut periods = merge_adjacent(periods);
    for period in &mut periods {
        let original_end = period.end_ds;
        let end_unix = unix_s_at(original_end, period.captured_unix);
        for &(support_ds, support_captured) in sleep_support {
            let raw_delta_ds = support_ds - original_end;
            if !(0..=MAX_SLEEP_SIGNAL_EXTENSION_DS).contains(&raw_delta_ds) {
                continue;
            }
            let wall_delta_s = unix_s_at(support_ds, support_captured) - end_unix;
            let same_epoch =
                (wall_delta_s - raw_delta_ds as f64 / 10.0).abs() <= EPOCH_ALIGNMENT_SLACK_S;
            if same_epoch
                && (0.0..=MAX_SLEEP_SIGNAL_EXTENSION_DS as f64 / 10.0).contains(&wall_delta_s)
            {
                period.end_ds = period.end_ds.max(support_ds);
            }
        }
        let raw_duration = period.raw_end_ds - period.raw_start_ds;
        let explicit_extension = period.end_ds - period.raw_end_ds;
        if raw_duration >= MIN_LONG_SLEEP_DS && explicit_extension >= MIN_PREMATURE_END_EVIDENCE_DS
        {
            period.end_ds = pulse_continuation_end(
                period.raw_end_ds,
                period.end_ds,
                period.captured_unix,
                pulse_support,
                unix_s_at,
            );
        }
    }
    merge_adjacent(periods)
}

/// Mean HR / HRV within each sleep stage, mapping each timestamped sample to the
/// hypnogram epoch it falls in (stages tile [start_ds, end_ds] uniformly). Codes
/// 1=deep 2=light 3=rem; wake is excluded (not recovery). Returns per-stage means where
/// samples exist, else `null`.
///
/// We deliberately expose per-stage means (esp. deep-sleep HRV, the cleanest recovery
/// signal) rather than a single overnight HRV slope: nocturnal HRV is stage-driven
/// (deep ↑, REM ↓), so a naive slope mostly tracks stage ordering, not recovery — a point
/// the sleep-HRV literature makes explicitly and which Oura's own app avoids.
fn autonomic_by_stage(
    hrv_t: &[(i64, f64)],
    hr_t: &[(i64, f64)],
    stages: &[i64],
    start_ds: i64,
    end_ds: i64,
) -> Value {
    if stages.is_empty() {
        return Value::Null;
    }
    let span = (end_ds - start_ds).max(1) as f64;
    let n = stages.len();
    let stage_at = |time_ds: i64| -> Option<i64> {
        let f = (time_ds - start_ds) as f64 / span;
        if !(0.0..=1.0).contains(&f) {
            return None;
        }
        Some(stages[((f * n as f64) as usize).min(n - 1)])
    };
    // per stage code: (hrv_sum, hrv_n, hr_sum, hr_n)
    let mut acc: std::collections::HashMap<i64, (f64, u32, f64, u32)> = Default::default();
    for &(t, v) in hrv_t {
        if let Some(s) = stage_at(t) {
            let e = acc.entry(s).or_default();
            e.0 += v;
            e.1 += 1;
        }
    }
    for &(t, v) in hr_t {
        if let Some(s) = stage_at(t) {
            let e = acc.entry(s).or_default();
            e.2 += v;
            e.3 += 1;
        }
    }
    let hrv = |c: i64| {
        acc.get(&c)
            .filter(|e| e.1 > 0)
            .map(|e| (e.0 / e.1 as f64).round())
    };
    let hr = |c: i64| {
        acc.get(&c)
            .filter(|e| e.3 > 0)
            .map(|e| (e.2 / e.3 as f64).round())
    };
    json!({
        "hrv_deep": hrv(1), "hrv_light": hrv(2), "hrv_rem": hrv(3),
        "hr_deep":  hr(1),  "hr_light":  hr(2),  "hr_rem":  hr(3),
    })
}

/// Count maximal runs of `code` at least `min_len` epochs long.
fn count_bouts(seq: &[i64], code: i64, min_len: usize) -> u32 {
    let mut count = 0;
    let mut run = 0usize;
    for &c in seq {
        if c == code {
            run += 1;
        } else {
            if run >= min_len {
                count += 1;
            }
            run = 0;
        }
    }
    if run >= min_len {
        count += 1;
    }
    count
}

/// Count periods of `code`, merging two runs separated by fewer than `merge_gap`
/// non-`code` epochs into one, then keeping only merged periods of at least `min_len`.
fn count_periods(seq: &[i64], code: i64, merge_gap: usize, min_len: usize) -> u32 {
    // collect (start,end) runs of the code
    let mut runs: Vec<(usize, usize)> = Vec::new();
    let mut i = 0;
    while i < seq.len() {
        if seq[i] == code {
            let start = i;
            while i < seq.len() && seq[i] == code {
                i += 1;
            }
            runs.push((start, i));
        } else {
            i += 1;
        }
    }
    if runs.is_empty() {
        return 0;
    }
    // merge runs closer than merge_gap
    let mut merged: Vec<(usize, usize)> = vec![runs[0]];
    for &(s, e) in &runs[1..] {
        let last = merged.last_mut().unwrap();
        if s - last.1 < merge_gap {
            last.1 = e;
        } else {
            merged.push((s, e));
        }
    }
    merged.iter().filter(|(s, e)| e - s >= min_len).count() as u32
}

/// Science-based per-night sleep metrics derived from the model hypnogram (per-epoch
/// codes 1=deep 2=light 3=rem 4=wake). The epoch length is inferred from the night's
/// in-bed window so we never hardcode the model's 30 s cadence. Returns clinical
/// readouts (onset latency, REM latency, WASO, awakenings, cycles, fragmentation) plus
/// the deep/REM front-vs-back-half split, and the asleep seconds used for sleep debt.
fn sleep_metrics(stages: &[i64], in_bed_s: f64) -> (Value, i32) {
    let n = stages.len();
    if n == 0 {
        return (Value::Null, 0);
    }
    let epoch_min = in_bed_s / 60.0 / n as f64;
    let is_sleep = |c: i64| (1..=3).contains(&c);
    let onset = stages.iter().position(|&c| is_sleep(c));
    let final_sleep = stages.iter().rposition(|&c| is_sleep(c));
    let (Some(onset), Some(final_sleep)) = (onset, final_sleep) else {
        return (Value::Null, 0);
    };
    let sleep_span = &stages[onset..=final_sleep];
    let asleep_epochs = stages.iter().filter(|&&c| is_sleep(c)).count();
    let asleep_min = asleep_epochs as f64 * epoch_min;

    // WASO + awakenings: wake epochs strictly inside the sleep period. An awakening is
    // a wake bout of at least ~1 min (min_wake epochs) so brief scoring flicker doesn't
    // inflate the count.
    let waso_epochs = sleep_span.iter().filter(|&&c| c == 4).count();
    let min_wake = (1.0 / epoch_min).ceil() as usize; // ≥ ~1 minute
    let awakenings = count_bouts(sleep_span, 4, min_wake.max(1));

    let rem_latency = stages[onset..]
        .iter()
        .position(|&c| c == 3)
        .map(|i| i as f64 * epoch_min);

    // Sleep cycles ≈ REM periods: a REM period is a run of REM, merging gaps shorter
    // than ~15 min and requiring the period to reach a few minutes — otherwise 30 s
    // REM flecks read as dozens of "cycles".
    let merge_gap = (15.0 / epoch_min).round() as usize;
    let min_rem = (3.0 / epoch_min).ceil() as usize;
    let cycles = count_periods(sleep_span, 3, merge_gap.max(1), min_rem.max(1));

    // fragmentation: stage changes per hour of sleep.
    let transitions = sleep_span.windows(2).filter(|w| w[0] != w[1]).count();
    let frag_index = if asleep_min > 0.0 {
        transitions as f64 / (asleep_min / 60.0)
    } else {
        0.0
    };

    // deep/REM concentration: share of each stage that falls in the first half of the
    // sleep period (healthy sleep front-loads deep, back-loads REM).
    let mid = onset + (final_sleep - onset) / 2;
    let half_pct = |code: i64| -> Option<f64> {
        let total = stages.iter().filter(|&&c| c == code).count();
        if total == 0 {
            return None;
        }
        let first = stages[onset..=mid].iter().filter(|&&c| c == code).count();
        Some((first as f64 / total as f64 * 100.0).round())
    };

    let round1 = |x: f64| (x * 10.0).round() / 10.0;
    let metrics = json!({
        "asleep_min": round1(asleep_min),
        "sol_min": round1(onset as f64 * epoch_min),
        "rem_latency_min": rem_latency.map(round1),
        "waso_min": round1(waso_epochs as f64 * epoch_min),
        "awakenings": awakenings,
        "cycles": cycles,
        "frag_index": round1(frag_index),
        "deep_first_half_pct": half_pct(1),
        "rem_first_half_pct": half_pct(3),
    });
    (metrics, (asleep_min * 60.0) as i32)
}

/// Personal baseline for a vital via ecore's annealing-EMA `Baseline`, over the nights
/// before the latest one. ecore anneals from zero over long history; the dashboard only
/// has a short window, so we prime the EMA at the first observed value (its mature
/// result is unchanged) and age it one "day" per night. `None` with < 2 valid nights.
fn ema_baseline(per_night: &[Option<f64>]) -> Option<f64> {
    use oura_analysis::ported::baseline::Baseline;
    let n = per_night.len();
    if n < 2 {
        return None;
    }
    let priors: Vec<f64> = per_night[..n - 1].iter().filter_map(|x| *x).collect();
    let (first, rest) = priors.split_first()?;
    let mut b = Baseline {
        mean_x8: (first.round() as i32) << 3,
        dev_x8: 0,
    };
    for (i, v) in rest.iter().enumerate() {
        b.update(v.round() as i32, (i + 1) as u32);
    }
    Some(b.mean())
}

/// `(sparkline series, latest, baseline)` for a per-night vital.
type VitalStat = (Vec<f64>, Option<f64>, Option<f64>);
fn vital_stat(per_night: &[Option<f64>]) -> VitalStat {
    let series: Vec<f64> = per_night.iter().filter_map(|x| *x).collect();
    let latest = per_night.last().copied().flatten();
    (series, latest, ema_baseline(per_night))
}
/// Percent change of `latest` vs `baseline`, guarding a zero/absent baseline.
fn vital_delta_pct(stat: &VitalStat) -> Option<f64> {
    match (stat.1, stat.2) {
        (Some(l), Some(b)) if b != 0.0 => Some(((l - b) / b * 100.0).round()),
        _ => None,
    }
}

fn feat(name: &str, on: bool, feature: &str) -> Value {
    json!({ "name": name, "on": on, "feature": feature })
}

/// Mode filter over a centered odd window — removes single-epoch flicker from the
/// model hypnogram so cycle/awakening counts reflect real architecture, not 30 s noise
/// (clinical scoring smooths the same way before deriving events).
fn smooth_stages(vals: &[i64], win: usize) -> Vec<i64> {
    if vals.len() < win || win < 3 {
        return vals.to_vec();
    }
    let half = win / 2;
    (0..vals.len())
        .map(|i| {
            let a = i.saturating_sub(half);
            let b = (i + half + 1).min(vals.len());
            let mut counts = [0u32; 5];
            for &s in &vals[a..b] {
                if (1..=4).contains(&s) {
                    counts[s as usize] += 1;
                }
            }
            (1..=4)
                .max_by_key(|&k| counts[k as usize])
                .unwrap_or(vals[i])
        })
        .collect()
}

/// Bucket-average a dense value series down to at most `n` points, so a per-sample
/// signal (SpO₂ has tens of thousands of samples/night) stays a light payload while
/// keeping its shape for the lane charts.
fn downsample_mean(v: &[f64], n: usize) -> Vec<f64> {
    if v.len() <= n {
        return v.to_vec();
    }
    let step = v.len() as f64 / n as f64;
    (0..n)
        .map(|i| {
            let a = (i as f64 * step) as usize;
            let b = (((i + 1) as f64 * step) as usize).max(a + 1).min(v.len());
            let slice = &v[a..b];
            slice.iter().sum::<f64>() / slice.len() as f64
        })
        .collect()
}

fn downsample_codes(vals: &[i64], n: usize) -> Vec<i64> {
    if vals.len() <= n {
        return vals.to_vec();
    }
    let step = vals.len() as f64 / n as f64;
    (0..n)
        .map(|i| {
            let a = (i as f64 * step) as usize;
            let b = ((i as f64 + 1.0) * step) as usize;
            let slice = &vals[a..b.min(vals.len()).max(a + 1)];
            let mut counts = [0u32; 5];
            for &s in slice {
                if (1..=4).contains(&s) {
                    counts[s as usize] += 1;
                }
            }
            (1..=4).max_by_key(|&k| counts[k as usize]).unwrap_or(2) as i64
        })
        .collect()
}

fn make_digest(hrv: &VitalStat, rhr: &VitalStat) -> String {
    let mut parts: Vec<String> = Vec::new();
    let hrv_pct = vital_delta_pct(hrv);
    let rhr_delta = match (rhr.1, rhr.2) {
        (Some(l), Some(b)) => Some(l - b),
        _ => None,
    };
    if let Some(p) = hrv_pct {
        parts.push(format!("HRV {}{:.0}%", if p >= 0.0 { "+" } else { "" }, p));
    }
    if let Some(d) = rhr_delta {
        parts.push(format!(
            "resting HR {}{:.0} bpm",
            if d >= 0.0 { "+" } else { "" },
            d
        ));
    }
    let recovering = match (hrv_pct, rhr_delta) {
        (Some(p), _) => p >= 0.0,
        (None, Some(d)) => d <= 0.0,
        (None, None) => false,
    };
    let mut s = parts.join(", ");
    if !s.is_empty() {
        s.push_str(if recovering {
            ". Recovering well."
        } else {
            ". Recovery dipping, take it easy."
        });
    }
    if s.is_empty() {
        s = "Synced. Not enough history yet for trends.".into();
    }
    s
}

/// Assemble the full dashboard summary as a JSON value. The torch models are
/// supplied by `runner` (Python subprocess on desktop, `.ptl` on-device).
pub fn build_summary(db: &Path, tz: i64, runner: &dyn ModelRunner) -> Result<Value> {
    let db_abs = std::fs::canonicalize(db).unwrap_or_else(|_| {
        std::env::current_dir()
            .map(|d| d.join(db))
            .unwrap_or_else(|_| db.to_path_buf())
    });
    let db = db_abs.as_path();
    let demo = read_profile(db);
    let store = Store::open(db).context("opening DB")?;
    let events = store.decoded_events().context("reading events")?;
    if events.is_empty() {
        return Err(anyhow!(
            "no decoded events in {} — run `oura sync` first",
            db.display()
        ));
    }
    let clock = RingClock::from_events(&events);
    let unix_s_at = |ds: i64, captured_unix: i64| clock.unix_s(ds, captured_unix);
    let anchor_unix = clock.latest_unix();
    let mut raw_beds: Vec<BedPeriod> = Vec::new();
    let mut sleep_support: Vec<(i64, i64)> = Vec::new();
    let mut pulse_support: Vec<(i64, i64, usize)> = Vec::new();
    let mut present_recent = std::collections::HashSet::new();
    // "recent" = within 10 days of the newest data, measured in wall-clock so it never
    // sweeps in an older epoch that happens to share a high raw ds.
    let recent_cut_unix = anchor_unix as f64 - 10.0 * 86_400.0;
    let name_of = |tag: u8| oura_protocol::events::event_name(tag);
    for (ds, tag, jstr, cu) in &events {
        let n = name_of(*tag);
        if unix_s_at(*ds, *cu) >= recent_cut_unix {
            present_recent.insert(n);
        }
        if n == "bedtime_period" {
            if let Ok(v) = serde_json::from_str::<Value>(jstr) {
                if let (Some(s), Some(e)) =
                    (v["bedtime_start_ds"].as_i64(), v["bedtime_end_ds"].as_i64())
                {
                    match raw_beds.iter_mut().find(|bed| {
                        bed.start_ds == s
                            && (unix_s_at(bed.start_ds, bed.captured_unix) - unix_s_at(s, *cu))
                                .abs()
                                <= 5.0 * 60.0
                    }) {
                        Some(bed) => {
                            bed.end_ds = bed.end_ds.max(e);
                            bed.raw_end_ds = bed.raw_end_ds.max(e);
                            bed.captured_unix = bed.captured_unix.max(*cu);
                        }
                        None => raw_beds.push(BedPeriod {
                            start_ds: s,
                            end_ds: e,
                            raw_start_ds: s,
                            raw_end_ds: e,
                            captured_unix: *cu,
                        }),
                    }
                }
            }
        }
        if matches!(
            n,
            "sleep_acm_period" | "sleep_temp_event" | "spo2_r_pi_event"
        ) {
            sleep_support.push((*ds, *cu));
        }
        // Both SleepNet implementations already consume these two streams. `hr_bpm`
        // is populated only when the firmware accepted a pulse estimate, so it is a
        // stronger continuation signal than raw/invalid IBI values.
        if matches!(n, "ibi_and_amplitude_event" | "green_ibi_quality_event") {
            if let Ok(v) = serde_json::from_str::<Value>(jstr) {
                if let Some(accepted) = v["hr_bpm"].as_array().map(Vec::len).filter(|&n| n > 0) {
                    pulse_support.push((*ds, *cu, accepted));
                }
            }
        }
    }
    let beds = normalize_bed_periods(raw_beds, &sleep_support, &pulse_support, unix_s_at);

    let mut nights: Vec<Night> = beds
        .iter()
        .map(|bed| Night {
            start_ds: bed.start_ds,
            end_ds: bed.end_ds,
            raw_start_ds: bed.raw_start_ds,
            raw_end_ds: bed.raw_end_ds,
            captured_unix: bed.captured_unix,
            ..Default::default()
        })
        .collect();
    let find_night = |ds: i64, captured_unix: i64, nights: &[Night]| {
        nights
            .iter()
            .enumerate()
            .filter(|(_, nt)| nt.start_ds - 600 <= ds && ds <= nt.end_ds + 600)
            .min_by_key(|(_, nt)| (nt.captured_unix - captured_unix).abs())
            .map(|(idx, _)| idx)
    };
    for (ds, tag, jstr, cu) in &events {
        let Some(idx) = find_night(*ds, *cu, &nights) else {
            continue;
        };
        let n = name_of(*tag);
        let v: Value = match serde_json::from_str(jstr) {
            Ok(v) => v,
            Err(_) => continue,
        };
        match n {
            "hrv_event" => {
                // Each array element is an `interval_min`-minute average starting at the
                // event's ring timestamp, so element i sits at ds + i·interval (in
                // deciseconds: minutes × 600). Keep both the flat vecs (mean/min) and the
                // timestamped samples (stage-resolved autonomics).
                let step_ds = v["interval_min"].as_i64().unwrap_or(5).max(1) * 600;
                if let Some(a) = v["rmssd_ms"].as_array() {
                    for (i, x) in a.iter().enumerate() {
                        if let Some(val) = x.as_f64() {
                            if val > 0.0 {
                                nights[idx].rmssd.push(val);
                                nights[idx].hrv_t.push((*ds + i as i64 * step_ds, val));
                            }
                        }
                    }
                }
                if let Some(a) = v["hr_bpm"].as_array() {
                    for (i, x) in a.iter().enumerate() {
                        if let Some(val) = x.as_f64() {
                            if val > 0.0 {
                                nights[idx].hr.push(val);
                                nights[idx].hr_t.push((*ds + i as i64 * step_ds, val));
                            }
                        }
                    }
                }
            }
            "sleep_temp_event" => {
                // Only the dedicated nocturnal stream is calibrated as skin
                // temperature. Generic `temp_event` contains several device/ambient
                // channels; mixing it here creates a false plunge when sleep mode ends.
                if let Some(a) = v["temps_c"].as_array() {
                    nights[idx]
                        .temp
                        .extend(a.iter().filter_map(|x| x.as_f64()).filter(|&c| c > 0.0));
                    nights[idx].temp_start_ds = Some(
                        nights[idx]
                            .temp_start_ds
                            .map_or(*ds, |current| current.min(*ds)),
                    );
                    nights[idx].temp_end_ds = Some(
                        nights[idx]
                            .temp_end_ds
                            .map_or(*ds, |current| current.max(*ds)),
                    );
                }
            }
            "spo2_r_pi_event" => {
                if let Some(a) = v["r"].as_array() {
                    nights[idx].spo2.extend(
                        a.iter()
                            .filter_map(|x| x.as_f64())
                            .filter(|&x| x > 0.0)
                            .map(spo2_pct),
                    );
                }
            }
            "motion_event" => {
                // seconds of motion in this window — a restlessness signal aligned to
                // the night, feeds the polysomnograph's movement lane.
                if let Some(s) = v["motion_seconds"].as_f64() {
                    nights[idx].motion.push(s);
                }
            }
            _ => {}
        }
    }

    // the model seam — sleep / cva / activity (Python subprocess or on-device .ptl)
    let sleep_ranges: Vec<[i64; 2]> = nights.iter().map(|nt| [nt.start_ds, nt.end_ds]).collect();
    let ModelOutputs {
        sleep_batch,
        cva,
        activity: activity_raw,
    } = runner.run(ModelInputs {
        db,
        tz,
        demo: &demo,
        sleep_ranges: &sleep_ranges,
    });

    let hyps: std::collections::HashMap<i64, Value> = sleep_batch
        .as_ref()
        .and_then(|v| v.as_array())
        .map(|arr| {
            arr.iter()
                .filter_map(|h| Some((h["start_ds"].as_i64()?, h.clone())))
                .collect()
        })
        .unwrap_or_default();

    nights.sort_by(|a, b| {
        unix_s_at(a.start_ds, a.captured_unix)
            .partial_cmp(&unix_s_at(b.start_ds, b.captured_unix))
            .unwrap_or(std::cmp::Ordering::Equal)
    });

    // downsample a raw signal to ≤N points (bucket mean) then round for a compact
    // payload; the frontend spreads each series evenly across the night window (all
    // signals cover the full night, so index→time is shared across lanes).
    const SERIES_MAX: usize = 240;
    let series = |v: &[f64], dp: i32| -> Vec<f64> {
        let m = 10f64.powi(dp);
        downsample_mean(v, SERIES_MAX)
            .iter()
            .map(|x| (x * m).round() / m)
            .collect()
    };

    let mut nights_json = Vec::new();
    let mut asleep_by_day: std::collections::BTreeMap<i64, i32> = Default::default();
    for nt in &nights {
        let hyp = hyps.get(&nt.start_ds);
        let raw_stages: Vec<i64> = hyp
            .and_then(|h| h["stages"].as_array())
            .map(|s| s.iter().filter_map(|x| x.as_i64()).collect())
            .unwrap_or_default();
        // smooth once (≈2.5 min window) — used for the displayed hypnogram AND the
        // derived metrics, so the two always agree.
        let full_stages = smooth_stages(&raw_stages, 5);
        let stage_cells = (!full_stages.is_empty()).then(|| downsample_codes(&full_stages, 120));
        let in_bed_s = (nt.end_ds - nt.start_ds) as f64 / 10.0;
        let (metrics, asleep_s) = sleep_metrics(&full_stages, in_bed_s);
        let autonomic =
            autonomic_by_stage(&nt.hrv_t, &nt.hr_t, &full_stages, nt.start_ds, nt.end_ds);
        let start_unix = unix_s_at(nt.start_ds, nt.captured_unix);
        let end_unix = unix_s_at(nt.end_ds, nt.captured_unix);
        let span_ds = (nt.end_ds - nt.start_ds).max(1) as f64;
        let temp_span = match (nt.temp_start_ds, nt.temp_end_ds) {
            (Some(start), Some(end)) => Some([
                ((start - nt.start_ds) as f64 / span_ds).clamp(0.0, 1.0),
                ((end - nt.start_ds) as f64 / span_ds).clamp(0.0, 1.0),
            ]),
            _ => None,
        };
        if asleep_s > 0 {
            let wake_day = (end_unix as i64 + tz * 3600).div_euclid(86_400);
            *asleep_by_day.entry(wake_day).or_default() += asleep_s;
        }
        nights_json.push(json!({
            "date": date_label(start_unix, tz),
            "ymd": ymd_label(start_unix, tz),
            "start_ds": nt.start_ds, // exact bedtime key for on-device model injection
            "end_ds": nt.end_ds,
            // Android's interim schema likewise preserves bedtime_start/end_original
            // beside detector-adjusted bounds. Keep both for audits and future models.
            "raw_start_ds": nt.raw_start_ds,
            "raw_end_ds": nt.raw_end_ds,
            "bedtime_adjusted": nt.start_ds != nt.raw_start_ds || nt.end_ds != nt.raw_end_ds,
            "start": hm(start_unix, tz),
            "end": hm(end_unix, tz),
            "in_bed_h": ((nt.end_ds - nt.start_ds) as f64 / 10.0 / 3600.0 * 10.0).round() / 10.0,
            "hrv_ms": mean(&nt.rmssd).map(|x| x.round()),
            "rhr": nt.hr.iter().cloned().fold(f64::INFINITY, f64::min).is_finite().then(|| nt.hr.iter().cloned().fold(f64::INFINITY, f64::min).round()),
            "skin_temp": nightly_skin_temp(&nt.temp).map(|x| (x * 10.0).round() / 10.0),
            "spo2_mean": mean(&nt.spo2).map(|x| x.round()),
            "deep_pct": hyp.map(|h| h["deep_pct"].clone()),
            "light_pct": hyp.map(|h| h["light_pct"].clone()),
            "rem_pct": hyp.map(|h| h["rem_pct"].clone()),
            "wake_pct": hyp.map(|h| h["wake_pct"].clone()),
            "efficiency": hyp.map(|h| h["efficiency_pct"].clone()),
            "stages": stage_cells,
            // full-resolution hypnogram + aligned raw signals for the detail page's
            // stacked polysomnograph (empty arrays stay out of the way when absent).
            "stages_full": (!full_stages.is_empty()).then_some(full_stages),
            "series": {
                "hr": series(&nt.hr, 0),
                "hrv": series(&nt.rmssd, 0),
                "temp": series(&nt.temp, 2),
                "temp_span": temp_span,
                "spo2": series(&nt.spo2, 0),
                "motion": series(&nt.motion, 0),
            },
            "metrics": metrics,
            // mean HR/HRV per sleep stage (deep/light/rem) — deep-sleep HRV is the
            // recovery-relevant number; null when there's no hypnogram.
            "autonomic": autonomic,
        }));
    }
    nights_json.reverse();

    let sleep_debt = sleep_debt_summary(&asleep_by_day);

    let mut activity = activity_raw
        .as_ref()
        .and_then(|v| v["sessions"].as_array().cloned())
        .unwrap_or_default();

    let mut prof_sum: std::collections::BTreeMap<String, [f64; 96]> = Default::default();
    let mut prof_cnt: std::collections::BTreeMap<String, [u32; 96]> = Default::default();
    let mut daily: std::collections::BTreeMap<String, (f64, f64)> = Default::default();
    let mut met_min: std::collections::BTreeMap<i64, f64> = Default::default();
    let weight = demo.weight_kg;
    // Resting daily expenditure via ecore's Schofield BMR (by age band + sex), instead
    // of the old flat `weight × 24` approximation. Added to active kcal for total kcal.
    let sex_code = match demo.sex {
        'F' => 1u8,
        'M' => 0,
        _ => 2, // unknown → the male/female average (bmr_schofield's fallback)
    };
    let bmr_kcal_day = oura_analysis::ported::metabolic::bmr_schofield(demo.age, sex_code, weight);
    // Anthropometric VO2max (Jackson non-exercise estimate), ecore's own formula.
    let vo2max =
        oura_analysis::ported::metabolic::vo2max_jackson(demo.age, demo.sex == 'F', weight);
    for (ds, tag, jstr, cu) in &events {
        if name_of(*tag) != "activity_information" || !jstr.contains("\"met\"") {
            continue;
        }
        if let Ok(v) = serde_json::from_str::<Value>(jstr) {
            if let Some(met) = v["met"].as_array() {
                for (i, m) in met.iter().enumerate() {
                    let mv = m.as_f64().unwrap_or(1.0);
                    let unix = unix_s_at(*ds, *cu) + i as f64 * 60.0;
                    let local = unix + tz as f64 * 3600.0;
                    let day_idx = (local / 86400.0).floor() as i64;
                    let (y, mo, dd) = civil(day_idx);
                    let key = format!("{y:04}-{mo:02}-{dd:02}");
                    let bucket = (((local - day_idx as f64 * 86400.0) / 86400.0) * 96.0)
                        .floor()
                        .clamp(0.0, 95.0) as usize;
                    prof_sum.entry(key.clone()).or_insert([0.0; 96])[bucket] += (mv - 1.0).max(0.0);
                    prof_cnt.entry(key.clone()).or_insert([0; 96])[bucket] += 1;
                    let step_rate = if mv >= 7.0 {
                        150.0
                    } else if mv >= 2.5 {
                        105.0
                    } else {
                        0.0
                    };
                    let e = daily.entry(key).or_insert((0.0, 0.0));
                    e.0 += (mv - 1.0).max(0.0) * weight / 60.0;
                    e.1 += step_rate;
                    *met_min.entry((local / 60.0).floor() as i64).or_insert(0.0) +=
                        (mv - 1.0).max(0.0);
                }
            }
        }
    }
    for sess in activity.iter_mut() {
        let (Some(start), Some(dur)) = (sess["start"].as_str(), sess["duration_min"].as_f64())
        else {
            continue;
        };
        let parse = || -> Option<i64> {
            let (date, time) = start.split_once(' ')?;
            let mut dp = date.split('-');
            let y: i64 = dp.next()?.parse().ok()?;
            let mo: u32 = dp.next()?.parse().ok()?;
            let dd: u32 = dp.next()?.parse().ok()?;
            let mut tp = time.split(':');
            let hh: i64 = tp.next()?.parse().ok()?;
            let mm: i64 = tp.next()?.parse().ok()?;
            Some(days_from_civil(y, mo, dd) * 1440 + hh * 60 + mm)
        };
        if let Some(m0) = parse() {
            let kcal: f64 = (m0..m0 + dur as i64)
                .filter_map(|m| met_min.get(&m))
                .map(|met| met * weight / 60.0)
                .sum();
            sess["active_kcal"] = json!(kcal.round());
        }
    }

    let activity_daily: Value = daily
        .iter()
        .map(|(k, (act, steps))| {
            let steps_r = (steps / 100.0).round() * 100.0;
            // walking distance from steps via ecore's actinfo_steps_to_meters (0.762 m/step)
            let distance_m = oura_analysis::ported::metabolic::steps_to_meters(steps_r as u32);
            (
                k.clone(),
                json!({
                    "active_kcal": act.round(),
                    "total_kcal": (bmr_kcal_day + act).round(),
                    "steps": steps_r,
                    "distance_m": distance_m,
                }),
            )
        })
        .collect::<serde_json::Map<_, _>>()
        .into();
    let activity_profile: Value = prof_sum
        .iter()
        .map(|(k, sums)| {
            let cnt = &prof_cnt[k];
            let arr: Vec<f64> = sums
                .iter()
                .zip(cnt.iter())
                .map(|(s, c)| {
                    if *c > 0 {
                        (s / *c as f64 * 100.0).round() / 100.0
                    } else {
                        0.0
                    }
                })
                .collect();
            (k.clone(), json!(arr))
        })
        .collect::<serde_json::Map<_, _>>()
        .into();

    let hrv_by_night: Vec<Option<f64>> = nights.iter().map(|n| mean(&n.rmssd)).collect();
    let rhr_by_night: Vec<Option<f64>> = nights
        .iter()
        .map(|n| n.hr.iter().cloned().reduce(f64::min))
        .collect();
    let hrv_stat = vital_stat(&hrv_by_night);
    let rhr_stat = vital_stat(&rhr_by_night);
    let trend = |stat: &VitalStat| -> Value {
        let (series, latest, base) = stat;
        json!({
            "series": series.iter().map(|x| x.round()).collect::<Vec<_>>(),
            "latest": latest.map(|x| x.round()),
            "baseline": base.map(|b| (b * 10.0).round() / 10.0),
            "delta_pct": vital_delta_pct(stat),
        })
    };

    let has = |evname: &str| present_recent.contains(evname);
    let modes = read_feature_modes(db);
    let cap_on = |feature: &str, present: bool| -> bool {
        modes
            .get(feature)
            .and_then(Value::as_i64)
            .map(|m| m != 0)
            .unwrap_or(present)
    };
    let measuring = json!([
        feat(
            "Daytime HR",
            cap_on(
                "daytime_hr",
                has("ibi_and_amplitude_event") || has("green_ibi_quality_event")
            ),
            "daytime_hr"
        ),
        feat("SpO2", cap_on("spo2", has("spo2_r_pi_event")), "spo2"),
        feat(
            "Exercise HR",
            cap_on("exercise_hr", has("ehr_trace_event")),
            "exercise_hr"
        ),
        feat(
            "Real steps",
            cap_on(
                "real_steps",
                has("real_step_event_feature_1") || has("real_step_event_feature_2")
            ),
            "real_steps"
        ),
        feat(
            "Cardio PPG (CVA)",
            cap_on("cva_ppg", has("cva_raw_ppg_data")),
            "cva_ppg"
        ),
    ]);

    let mut sc: std::collections::BTreeMap<&str, i64> = Default::default();
    for (_ds, tag, _j, _) in &events {
        let cat = match name_of(*tag) {
            "spo2_r_pi_event" => Some("Blood oxygen"),
            "ibi_and_amplitude_event" | "green_ibi_quality_event" => Some("Heart beats"),
            "ehr_trace_event" | "ehr_acm_intensity_event" => Some("Exercise HR"),
            "motion_event" | "sleep_acm_period" => Some("Motion"),
            "temp_event" | "sleep_temp_event" => Some("Skin temp"),
            "real_step_event_feature_1" | "real_step_event_feature_2" => Some("Steps"),
            "cva_raw_ppg_data" => Some("Cardio PPG"),
            _ => None,
        };
        if let Some(c) = cat {
            *sc.entry(c).or_insert(0) += 1;
        }
    }
    let mut sv: Vec<(&str, i64)> = sc.into_iter().collect();
    sv.sort_by_key(|b| std::cmp::Reverse(b.1));
    let streams = json!(sv
        .iter()
        .map(|(n, c)| json!({ "name": n, "count": c }))
        .collect::<Vec<_>>());

    let mut allc: std::collections::BTreeMap<&str, i64> = Default::default();
    for (_ds, tag, _j, _) in &events {
        *allc.entry(name_of(*tag)).or_insert(0) += 1;
    }
    let mut allv: Vec<(&str, i64)> = allc.into_iter().collect();
    allv.sort_by_key(|b| std::cmp::Reverse(b.1));
    let event_counts = json!(allv
        .iter()
        .map(|(n, c)| json!({ "name": n, "count": c }))
        .collect::<Vec<_>>());
    let insight = |name: &str, live: bool, why: &str| json!({"name": name, "status": if live {"live"} else {"gated"}, "why": why});
    let insights = json!([
        insight("Sleep stages", true, ""),
        insight(
            "Apnea / breathing",
            has("ibi_and_amplitude_event"),
            "needs overnight IBI"
        ),
        insight(
            "Cardiovascular age",
            has("cva_raw_ppg_data"),
            "enable cva_ppg"
        ),
        insight("SpO2", has("spo2_r_pi_event"), "enable spo2"),
        insight("Activity sessions", true, ""),
        insight("HRV / resting HR", true, ""),
        insight(
            "Steps",
            has("real_step_event_feature_1") || has("real_step_event_feature_2"),
            "enable real_steps"
        ),
        insight("Stress / resilience", false, "needs cloud scores"),
    ]);
    let mut battery: Option<(i64, i64)> = None;
    for (_ds, tag, jstr, _) in &events {
        if name_of(*tag) == "debug_data" && jstr.contains("battery_pct") {
            if let Ok(v) = serde_json::from_str::<Value>(jstr) {
                if let Some(p) = v["battery_pct"].as_i64() {
                    battery = Some((p, v["voltage_mv"].as_i64().unwrap_or(0)));
                }
            }
        }
    }

    let dev = store.device_info().ok().flatten();
    let last_sync = dev.as_ref().map(|d| d.6).filter(|&t| t > 0);
    let synced_unix = last_sync.map(|t| t as f64);

    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs() as f64)
        .unwrap_or(anchor_unix as f64);
    let device = json!({
        "serial": dev.as_ref().map(|d| d.0.clone()),
        "hardware_id": dev.as_ref().map(|d| d.1.clone()).filter(|s| !s.is_empty()),
        "firmware": dev.as_ref().map(|d| d.2.clone()).filter(|s| !s.is_empty()),
        "api_version": dev.as_ref().map(|d| d.3.clone()).filter(|s| !s.is_empty()),
        "mac": dev.as_ref().map(|d| d.4.clone()).filter(|s| !s.is_empty()),
        "synced": synced_unix.map(|s| date_label(s, tz)),
        "synced_hm": synced_unix.map(|s| hm(s, tz)),
        "fresh_hours": synced_unix.map(|s| ((now - s) / 3600.0 * 10.0).round() / 10.0),
        "days_of_data": ((clock.total_span_ds() as f64 / 10.0 / 86400.0) * 10.0).round() / 10.0,
        "total_events": events.len(),
        "nights": nights.len(),
        "battery_pct": battery.map(|b| b.0),
        "battery_v": battery.map(|b| (b.1 as f64 / 1000.0 * 100.0).round() / 100.0),
        "measuring": measuring,
        "streams": streams,
        "event_counts": event_counts,
        "next_cursor": dev.as_ref().map(|d| d.7),
        "insights": insights,
    });

    let digest = make_digest(&hrv_stat, &rhr_stat);

    Ok(json!({
        "generated_at": now,
        "tz": tz,
        "digest": digest,
        "device": device,
        "profile": demo.to_json(),
        "nights": nights_json,
        "sleep_debt": sleep_debt,
        "cardio": cva,
        "fitness": { "vo2max": (vo2max * 10.0).round() / 10.0 },
        "activity": activity,
        "activity_profile": activity_profile,
        "activity_daily": activity_daily,
        "vitals": { "hrv": trend(&hrv_stat), "rhr": trend(&rhr_stat) },
    }))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn bed(start_ds: i64, end_ds: i64) -> BedPeriod {
        BedPeriod {
            start_ds,
            end_ds,
            raw_start_ds: start_ds,
            raw_end_ds: end_ds,
            captured_unix: 1,
        }
    }

    #[test]
    fn sleep_debt_aggregates_sessions_and_uses_fourteen_calendar_days() {
        let mut sleep = std::collections::BTreeMap::new();
        for day in 100..105 {
            sleep.insert(day, 7 * 3600);
        }
        // A one-hour nap belongs to the latest calendar day, making its total 8 h.
        *sleep.entry(104).or_default() += 3600;
        let value = sleep_debt_summary(&sleep);
        assert_eq!(value["valid"], true);
        assert_eq!(value["valid_days"], 5);
        assert_eq!(value["days"].as_array().unwrap().len(), 14);
        assert_eq!(value["days"][13]["total_sleep_min"], 480.0);
        assert_eq!(value["recent_shortfall_min"], 0.0);
    }

    #[test]
    fn sleep_debt_requires_five_distinct_days_not_five_sessions() {
        let sleep = std::collections::BTreeMap::from([
            (100, 8 * 3600),
            (101, 8 * 3600),
            (102, 8 * 3600),
            (103, 8 * 3600),
        ]);
        let value = sleep_debt_summary(&sleep);
        assert_eq!(value["valid"], false);
        assert_eq!(value["valid_days"], 4);
    }

    #[test]
    fn brief_wake_does_not_split_one_night() {
        let periods = vec![
            bed(0, 5 * 3600 * 10),
            bed(5 * 3600 * 10 + 7 * 60 * 10, 7 * 3600 * 10),
        ];
        let got = normalize_bed_periods(periods, &[], &[], |ds, _| ds as f64 / 10.0);
        assert_eq!(got, vec![bed(0, 7 * 3600 * 10)]);
    }

    #[test]
    fn nocturnal_signals_extend_a_premature_bedtime_end() {
        let support_end = 7 * 3600 * 10;
        let got = normalize_bed_periods(
            vec![bed(0, 5 * 3600 * 10)],
            &[(support_end, 1)],
            &[],
            |ds, _| ds as f64 / 10.0,
        );
        assert_eq!(got.len(), 1);
        assert_eq!(got[0].end_ds, support_end);
        assert_eq!(got[0].raw_end_ds, 5 * 3600 * 10);
    }

    #[test]
    fn clustered_valid_pulses_recover_sleep_after_brief_wakes() {
        let minute = 60 * 10;
        // Observed Ring 5 shape: explicit sleep streams stop at 05:34, followed by
        // short good-IBI bursts roughly every ten minutes through 06:27. A final lone
        // poor-quality packet at 06:38 must not extend the window.
        let raw_end = 0;
        let explicit_end = 93 * minute;
        let mut pulses = Vec::new();
        for offset_min in [105, 116, 126, 136, 146] {
            pulses.push((offset_min * minute, 1, 1));
            pulses.push((offset_min * minute + 10 * 10, 1, 1));
        }
        pulses.push((157 * minute, 1, 1));
        let got = normalize_bed_periods(
            vec![bed(-6 * 3600 * 10, raw_end)],
            &[(explicit_end, 1)],
            &pulses,
            |ds, _| ds as f64 / 10.0,
        );
        assert_eq!(got[0].end_ds, 146 * minute + 10 * 10);
        assert_eq!(got[0].raw_end_ds, raw_end);
    }

    #[test]
    fn isolated_daytime_pulse_does_not_extend_sleep() {
        let minute = 60 * 10;
        let got = normalize_bed_periods(
            vec![bed(-6 * 3600 * 10, 0)],
            &[],
            &[(10 * minute, 1, 4)],
            |ds, _| ds as f64 / 10.0,
        );
        assert_eq!(got[0].end_ds, 0);
    }

    #[test]
    fn daytime_nap_is_not_extended_by_periodic_hr_sampling() {
        let minute = 60 * 10;
        let pulses: Vec<_> = (10..=150).step_by(10).map(|m| (m * minute, 1, 6)).collect();
        let got = normalize_bed_periods(
            vec![bed(-20 * minute, 0)],
            &[(5 * minute, 1)],
            &pulses,
            |ds, _| ds as f64 / 10.0,
        );
        assert_eq!(got[0].end_ds, 5 * minute);
    }

    #[test]
    fn clean_long_sleep_end_is_not_extended_by_daytime_hr_sampling() {
        let minute = 60 * 10;
        let pulses = [(30 * minute, 1, 6), (30 * minute + 30 * 10, 1, 6)];
        let got = normalize_bed_periods(
            vec![bed(-7 * 60 * minute, 0)],
            &[(20 * minute, 1)],
            &pulses,
            |ds, _| ds as f64 / 10.0,
        );
        assert_eq!(got[0].end_ds, 20 * minute);
    }

    #[test]
    fn pulse_cluster_after_long_gap_does_not_extend_sleep() {
        let minute = 60 * 10;
        let pulses = [(20 * minute, 1, 2), (20 * minute + 10 * 10, 1, 2)];
        let got = normalize_bed_periods(vec![bed(-6 * 3600 * 10, 0)], &[], &pulses, |ds, _| {
            ds as f64 / 10.0
        });
        assert_eq!(got[0].end_ds, 0);
    }

    #[test]
    fn daytime_gap_remains_a_separate_sleep() {
        let periods = vec![bed(0, 30 * 60 * 10), bed(4 * 3600 * 10, 11 * 3600 * 10)];
        let got = normalize_bed_periods(periods.clone(), &[], &[], |ds, _| ds as f64 / 10.0);
        assert_eq!(got, periods);
    }
}
