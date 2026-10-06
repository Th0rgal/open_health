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

pub mod hourly_hr;
pub mod ring_time;
pub mod sleep_score;
pub mod symptoms;

/// An unanchored ring-clock epoch at least this long is worth a warning.
const UNANCHORED_WARN_H: f64 = 12.0;

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
    pub tz: f64,
    pub demo: &'a Demographics,
    pub sleep_ranges: &'a [[i64; 3]],
}

/// Raw model outputs, matching the Python runners' `--json` shape.
#[derive(Default)]
pub struct ModelOutputs {
    pub sleep_batch: Option<Value>, // run_sleep_model.py --batch
    pub cva: Option<Value>,         // run_cva_model.py
    pub activity: Option<Value>,    // run_activity_model.py
    pub illness: Option<Value>,     // run_illness_model.py (Symptom Radar)
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

/// User-adjusted bedtime/wake-up bounds (in ring deciseconds) for a specific night,
/// keyed by `"{raw_start_ds}:{captured_unix}"` (with fallback to `"{raw_start_ds}"`).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct BedtimeOverride {
    pub start_ds: i64,
    pub end_ds: i64,
}

pub fn bedtime_overrides_path(db: &Path) -> PathBuf {
    db.parent()
        .unwrap_or(Path::new("."))
        .join("bedtime_overrides.json")
}

pub fn read_bedtime_overrides(db: &Path) -> std::collections::HashMap<String, BedtimeOverride> {
    let mut out = std::collections::HashMap::new();
    let Some(Value::Object(map)) = std::fs::read_to_string(bedtime_overrides_path(db))
        .ok()
        .and_then(|s| serde_json::from_str::<Value>(&s).ok())
    else {
        return out;
    };
    for (k, v) in map {
        if let (Some(s), Some(e)) = (v["start_ds"].as_i64(), v["end_ds"].as_i64()) {
            if e > s && e - s <= 24 * 36_000 {
                out.insert(
                    k,
                    BedtimeOverride {
                        start_ds: s,
                        end_ds: e,
                    },
                );
            }
        }
    }
    out
}

/// Set or clear (`start_ds = None` or `end_ds = None`) a manual bedtime override for a night.
pub fn write_bedtime_override(
    db: &Path,
    raw_start_ds: i64,
    captured_unix: Option<i64>,
    start_ds: Option<i64>,
    end_ds: Option<i64>,
) -> Result<Value> {
    let path = bedtime_overrides_path(db);
    let mut map = match std::fs::read_to_string(&path)
        .ok()
        .and_then(|s| serde_json::from_str::<Value>(&s).ok())
    {
        Some(Value::Object(m)) => m,
        _ => serde_json::Map::new(),
    };
    let key = match captured_unix {
        Some(cu) => format!("{raw_start_ds}:{cu}"),
        None => format!("{raw_start_ds}"),
    };
    let legacy_key = format!("{raw_start_ds}");
    match (start_ds, end_ds) {
        (Some(s), Some(e)) => {
            if e <= s || e - s < 18_000 || e - s > 20 * 36_000 {
                return Err(anyhow!(
                    "bedtime duration must be between 30 minutes and 20 hours"
                ));
            }
            map.insert(key, json!({ "start_ds": s, "end_ds": e }));
        }
        _ => {
            map.remove(&key);
            map.remove(&legacy_key);
        }
    }
    std::fs::write(&path, serde_json::to_vec_pretty(&Value::Object(map))?)
        .context("writing bedtime_overrides.json")?;
    Ok(json!({ "ok": true }))
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

/// Fixed UTC offset in hours. Accepts legacy integer callers and fractional offsets.
#[derive(Clone, Copy)]
pub struct OffsetHours(pub f64);
impl From<i64> for OffsetHours {
    fn from(v: i64) -> Self {
        Self(v as f64)
    }
}
impl From<i32> for OffsetHours {
    fn from(v: i32) -> Self {
        Self(v as f64)
    }
}
impl From<f64> for OffsetHours {
    fn from(v: f64) -> Self {
        Self(v)
    }
}
fn offset_seconds(tz: f64) -> i64 {
    (tz * 3600.0).round() as i64
}

fn date_label(unix_s: f64, tz: impl Into<OffsetHours>) -> String {
    let tz = tz.into().0;
    let days = (unix_s as i64 + offset_seconds(tz)).div_euclid(86400);
    let (_, m, d) = civil(days);
    let wd = WD[(days + 3).rem_euclid(7) as usize];
    format!("{wd} {m:02}-{d:02}")
}
/// Full calendar date (`YYYY-MM-DD`) — an unambiguous key for matching a night to a
/// day's activity (the weekday `date_label` collides across years).
fn ymd_label(unix_s: f64, tz: impl Into<OffsetHours>) -> String {
    let tz = tz.into().0;
    let days = (unix_s as i64 + offset_seconds(tz)).div_euclid(86400);
    let (y, m, d) = civil(days);
    format!("{y:04}-{m:02}-{d:02}")
}

const SLEEP_DEBT_DAYS: i64 = 14;
/// Fallback need while there isn't enough history to personalize.
const SLEEP_NEED_DEFAULT_H: f64 = 8.0;
const SLEEP_NEED_WINDOW_DAYS: i64 = 90;
const SLEEP_NEED_MIN_VALID_DAYS: usize = 14;
const SLEEP_NEED_FLOOR_S: f64 = 7.0 * 3600.0;
const SLEEP_NEED_CEIL_S: f64 = 9.0 * 3600.0;
const SLEEP_NEED_ROUND_S: f64 = 900.0;

/// Personalized daily sleep need, matching what the Oura app feeds ecore's
/// `sleep_debt_calculate` (`SleepDebtInput.longTermSleepTimeAvgSeconds`, the
/// long-term `sleepTimeAvg` baseline): the user's typical sleep over the last
/// ~3 months, with unusually short or long days filtered out. Causal — only
/// days strictly before `day` count, so a night never sets its own need.
/// The IQR fence is our outlier filter (Oura only documents "unusually short
/// or extra-long nights are filtered out"), and the result is clamped to the
/// 7–9 h band the app itself cites so chronic under-sleep can't ratify itself
/// as a low need. Falls back to 8 h until 14 valid days exist.
fn sleep_need_s(asleep_by_day: &std::collections::BTreeMap<i64, i32>, day: i64) -> i32 {
    let mut vals: Vec<f64> = asleep_by_day
        .range(day - SLEEP_NEED_WINDOW_DAYS..day)
        .map(|(_, &s)| s as f64)
        .filter(|&s| s > 0.0)
        .collect();
    if vals.len() < SLEEP_NEED_MIN_VALID_DAYS {
        return (SLEEP_NEED_DEFAULT_H * 3600.0) as i32;
    }
    vals.sort_by(f64::total_cmp);
    let quantile = |p: f64| -> f64 {
        let idx = p * (vals.len() - 1) as f64;
        let (lo, hi) = (idx.floor() as usize, idx.ceil() as usize);
        vals[lo] + (vals[hi] - vals[lo]) * (idx - lo as f64)
    };
    let (q1, q3) = (quantile(0.25), quantile(0.75));
    let fence = 1.5 * (q3 - q1);
    let kept: Vec<f64> = vals
        .iter()
        .copied()
        .filter(|&v| v >= q1 - fence && v <= q3 + fence)
        .collect();
    let mean = kept.iter().sum::<f64>() / kept.len() as f64;
    let need = mean.clamp(SLEEP_NEED_FLOOR_S, SLEEP_NEED_CEIL_S);
    ((need / SLEEP_NEED_ROUND_S).round() * SLEEP_NEED_ROUND_S) as i32
}

/// Android's sleep-debt screen works on calendar days, not individual sleep sessions:
/// a main sleep and a nap ending on the same day both contribute to that day's total.
/// Build the complete 14-day series here so every client renders the same result.
fn sleep_debt_summary(asleep_by_day: &std::collections::BTreeMap<i64, i32>) -> Value {
    use oura_analysis::ported::sleep_debt::{sleep_debt, SleepDebtConfig};

    let Some(&anchor) = asleep_by_day.keys().next_back() else {
        return json!({
            "debt_min": 0, "recent_shortfall_min": 0, "valid": false,
            "need_h": SLEEP_NEED_DEFAULT_H, "valid_days": 0, "window_days": SLEEP_DEBT_DAYS,
            "state": "none", "days": [],
        });
    };
    let first = anchor - (SLEEP_DEBT_DAYS - 1);
    let mut days = Vec::with_capacity(SLEEP_DEBT_DAYS as usize);

    // ecore takes a per-day need array, so each day of the window is scored
    // against the need that was current *that* day.
    let window = |day: i64| -> (Vec<i32>, Vec<i32>) {
        let range = (day - (SLEEP_DEBT_DAYS - 1)..=day).rev();
        let actual = range
            .clone()
            .map(|d| asleep_by_day.get(&d).copied().unwrap_or(0))
            .collect();
        let need = range.map(|d| sleep_need_s(asleep_by_day, d)).collect();
        (actual, need)
    };

    for day in first..=anchor {
        let (actual, need) = window(day);
        let debt = sleep_debt(&actual, &need, &SleepDebtConfig::default());
        let total = asleep_by_day.get(&day).copied();
        let need_s = sleep_need_s(asleep_by_day, day);
        let valid_days = actual.iter().filter(|&&s| s > 0).count();
        let (y, m, d) = civil(day);
        days.push(json!({
            "date": format!("{y:04}-{m:02}-{d:02}"),
            "total_sleep_min": total.map(|s| (s as f64 / 60.0).round()),
            "sleep_need_min": (need_s as f64 / 60.0).round(),
            "shortfall_min": total.map(|s| ((need_s - s) as f64 / 60.0).round()),
            "cumulative_debt_min": debt.valid.then(|| (debt.debt_s as f64 / 60.0).round()),
            "valid_days": valid_days,
        }));
    }

    let (actual, need) = window(anchor);
    let valid_days = actual.iter().filter(|&&s| s > 0).count();
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
        "need_h": (sleep_need_s(asleep_by_day, anchor) as f64 / 3600.0 * 100.0).round() / 100.0,
        "valid_days": valid_days,
        "window_days": SLEEP_DEBT_DAYS,
        "state": state,
        "days": days,
    })
}
fn hm(unix_s: f64, tz: impl Into<OffsetHours>) -> String {
    let tz = tz.into().0;
    let sod = (unix_s as i64 + offset_seconds(tz)).rem_euclid(86400);
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
/// Median of a sample, or `None` when empty. Used for the night's respiratory rate,
/// where a median shrugs off the handful of windows the ring gets wrong.
fn median_of(values: &[f64]) -> Option<f64> {
    if values.is_empty() {
        return None;
    }
    let mut sorted: Vec<f64> = values.to_vec();
    sorted.sort_by(f64::total_cmp);
    let mid = sorted.len() / 2;
    Some(if sorted.len() % 2 == 0 {
        (sorted[mid - 1] + sorted[mid]) / 2.0
    } else {
        sorted[mid]
    })
}

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
    manual_bedtime: bool,
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
    // timestamped twins of `spo2`/`temp`/`motion` for the time-true `series_t` lanes;
    // samples packed in one event sit at that event's time.
    spo2_t: Vec<(i64, f64)>,
    temp_t: Vec<(i64, f64)>,
    motion_t: Vec<(i64, f64)>,
    /// Respiratory rate, breaths per minute, from the ring's own per-window estimate
    /// (`sleep_period_information_2.breath`) — only windows it scored as sleep, since
    /// an awake breath rate is not the biomarker. One of the four Symptom Radar inputs.
    breath: Vec<f64>,
}

#[derive(Clone, Copy, Debug, PartialEq)]
struct BedPeriod {
    start_ds: i64,
    end_ds: i64,
    raw_start_ds: i64,
    raw_end_ds: i64,
    captured_unix: i64,
    /// True when the ring itself staged this sleep (`sleep_phase_data`). Its end is
    /// then the ring's own verdict, not a window that stopped early, so the
    /// sleep-signal extension below must leave it alone.
    staged: bool,
}

const MAX_BED_BREAK_DS: i64 = 60 * 60 * 10;
const MAX_SLEEP_SIGNAL_EXTENSION_DS: i64 = 3 * 60 * 60 * 10;
const EPOCH_ALIGNMENT_SLACK_S: f64 = 5.0 * 60.0;
const PULSE_BURST_GAP_DS: i64 = 2 * 60 * 10;
const MAX_PULSE_CONTINUATION_GAP_DS: i64 = 15 * 60 * 10;
const MIN_ACCEPTED_BEATS_PER_BURST: usize = 2;
const MIN_LONG_SLEEP_DS: i64 = 3 * 60 * 60 * 10;
/// A run of nocturnal-only events shorter than this is not called a night on its own.
const MIN_DERIVED_BED_DS: i64 = 60 * 60 * 10;
const MIN_PREMATURE_END_EVIDENCE_DS: i64 = 30 * 60 * 10;
/// How much battery history the summary carries (see `battery_history`).
const BATTERY_HISTORY_DAYS: i64 = 14;
/// Longest silence in the sleep streams that still carries a night past the ring's own
/// bedtime end. A real Ring 4 night never paused them for more than 6.5 min; a still
/// spell 2.5 h after waking (resting SpO2/temperature packets) must not join the night.
const MAX_SLEEP_SUPPORT_GAP_DS: i64 = 30 * 60 * 10;

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
/// One sleep the ring analysed and staged: a contiguous `sleep_phase_data` page burst,
/// placed in time by [`ring_sleep_runs`].
struct RingSleep {
    start_ds: i64,
    end_ds: i64,
    captured_unix: i64,
    codes: Vec<i64>,
}

/// Assemble `sleep_phase_data` pages into analysed sleeps and place them in time.
///
/// Pages arrive as a burst with `header` counting up from zero, so a header that does
/// not follow the previous one starts a new sleep. A page carries only the `ds` at
/// which the ring emitted it — writing happens when analysis finishes, i.e. at the end
/// of the sleep — so a run ends at its last page and runs back at 30 s an epoch.
fn ring_sleep_runs(pages: &[(i64, i64, i64, Vec<i64>)]) -> Vec<RingSleep> {
    let epoch_ds = (RING_STAGE_EPOCH_S * 10.0) as i64;
    let mut runs: Vec<RingSleep> = Vec::new();
    let mut previous_page = -1i64;
    for (ds, captured, page, codes) in pages {
        match runs.last_mut() {
            Some(run) if *page == previous_page + 1 => {
                run.end_ds = *ds;
                run.captured_unix = *captured;
                run.codes.extend_from_slice(codes);
            }
            _ => runs.push(RingSleep {
                start_ds: *ds,
                end_ds: *ds,
                captured_unix: *captured,
                codes: codes.clone(),
            }),
        }
        previous_page = *page;
    }
    for run in &mut runs {
        run.start_ds = run.end_ds - run.codes.len() as i64 * epoch_ds;
    }
    runs
}

/// One `sleep_phase_data` stage epoch, in the codes the rest of the pipeline speaks:
/// 0=unknown 1=deep 2=light 3=rem 4=wake.
fn stage_code(phase: &str) -> i64 {
    match phase {
        "deep" => 1,
        "light" => 2,
        "rem" => 3,
        "awake" => 4,
        _ => 0,
    }
}

/// Seconds of sleep per `sleep_phase_data` epoch.
const RING_STAGE_EPOCH_S: f64 = 30.0;

/// The ring's OWN hypnogram, assembled from `sleep_phase_data` (tag `0x5a`).
///
/// Upstream lists this event as "not emitted yet"; a Gen 3 on fw 3.4.3 emits it — 52
/// epochs per 14-byte page, pages numbered by the `header` byte, the whole set written
/// in one burst when the ring finishes analysing a sleep. So Oura's own staging is
/// available with no model at all, and this is what fills the hypnogram in a
/// model-free build.
///
/// **Placing it in time.** The pages carry no timestamp of their own — their `ds` is
/// when the ring emitted them, not when you slept. Anchoring the run to END at the
/// last page's emission and running back at 30 s an epoch was checked against the
/// ring's independent per-window record for the night in question:
///
/// | | median HR | median motion | `sleep_state`=1 |
/// |---|---|---|---|
/// | inside the inferred window | 58.5 | 0 | 79% |
/// | in bed before it | 76.8 | 5 | 20% |
///
/// Asleep versus awake-in-bed, from data the hypnogram never touched. The anchor holds.
///
/// Unanalysed epochs are unknown (0), not evidence of wakefulness. Partial
/// coverage must not manufacture sleep latency, efficiency or sleep debt.
fn ring_hypnograms(
    runs: &[RingSleep],
    nights: &[Night],
    unix_s_at: impl Fn(i64, i64) -> f64,
) -> Vec<((i64, i64), Value)> {
    let mut out = Vec::new();
    for night in nights {
        let span_ds = night.end_ds - night.start_ds;
        if span_ds <= 0 {
            continue;
        }
        let epoch_ds = (RING_STAGE_EPOCH_S * 10.0) as i64;
        let cells = (span_ds / epoch_ds).max(1) as usize;
        let mut stages = vec![0i64; cells];
        let mut painted = false;
        for run in runs {
            // Relative counters overlap across boots; reject runs from other epochs.
            if (unix_s_at(run.end_ds, run.captured_unix)
                - unix_s_at(run.end_ds, night.captured_unix))
            .abs()
                > EPOCH_ALIGNMENT_SLACK_S
            {
                continue;
            }
            // keep a run that lies within this night's window (either end may hang over)
            if run.end_ds <= night.start_ds || run.start_ds >= night.end_ds {
                continue;
            }
            for (i, code) in run.codes.iter().enumerate() {
                let at = run.start_ds + i as i64 * epoch_ds;
                if at < night.start_ds || at >= night.end_ds {
                    continue;
                }
                stages[(((at - night.start_ds) / epoch_ds) as usize).min(cells - 1)] = *code;
                painted = true;
            }
        }
        if !painted {
            continue;
        }
        let share = |code: i64| {
            let n = stages.iter().filter(|&&c| c == code).count();
            (n as f64 / stages.len() as f64 * 1000.0).round() / 10.0
        };
        let asleep = stages.iter().filter(|&&c| (1..=3).contains(&c)).count();
        let complete = stages.iter().all(|c| (1..=4).contains(c));
        out.push((
            (night.start_ds, night.captured_unix),
            json!({
                "start_ds": night.start_ds,
                "stages": stages,
                "deep_pct": share(1),
                "light_pct": share(2),
                "rem_pct": share(3),
                "wake_pct": share(4),
                "efficiency_pct": complete.then(|| (asleep as f64 / stages.len() as f64 * 1000.0).round() / 10.0),
                "source": "ring",
            }),
        ));
    }
    out
}

/// When SleepNet runs on a night whose IBI stream lacks PPG pulse amplitude (e.g. Oura
/// Ring 4 `green_ibi_quality_event` `0x80`), it distinguishes WAKE (4), REM (3), and
/// NREM (2) but collapses slow-wave N3 into LIGHT (2), yielding 0 DEEP (1) epochs.
/// Recover consolidated N3 bouts inside LIGHT (2) using nocturnal HR, HRV, and motion:
/// contiguous motionless NREM runs (>= 6 min) with low HR weighted by homeostatic
/// Process S (stronger in the first two-thirds of the sleep period).
pub fn refine_deep_stages(
    stages: &[i64],
    hr_t: &[(i64, f64)],
    motion_t: &[(i64, f64)],
    start_ds: i64,
    end_ds: i64,
) -> Vec<i64> {
    let n = stages.len();
    if n < 120 || stages.contains(&1) || hr_t.len() < 12 || end_ds <= start_ds {
        return stages.to_vec();
    }
    let light_indices: Vec<usize> = stages
        .iter()
        .enumerate()
        .filter_map(|(i, &c)| (c == 2).then_some(i))
        .collect();
    if light_indices.len() < 60 {
        return stages.to_vec();
    }
    let span_ds = (end_ds - start_ds).max(1) as f64;
    let hr_vals: Vec<f64> = hr_t.iter().map(|&(_, v)| v).collect();
    let sample_hr = |idx: usize| -> f64 {
        let pos = idx as f64 / (n.saturating_sub(1).max(1) as f64)
            * (hr_vals.len().saturating_sub(1) as f64);
        let lo = (pos.floor() as usize).min(hr_vals.len() - 1);
        let hi = (lo + 1).min(hr_vals.len() - 1);
        let frac = pos - lo as f64;
        hr_vals[lo] * (1.0 - frac) + hr_vals[hi] * frac
    };
    let mut epoch_mo = vec![0.0f64; n];
    for &(ds, val) in motion_t {
        let f = ((ds - start_ds) as f64 / span_ds).clamp(0.0, 0.999_999);
        let idx = ((f * n as f64) as isize).clamp(0, n as isize - 1);
        for d in -1..=1 {
            let k = idx + d;
            if (0..n as isize).contains(&k) {
                let ku = k as usize;
                epoch_mo[ku] = epoch_mo[ku].max(val);
            }
        }
    }
    let mut runs: Vec<(usize, usize)> = Vec::new();
    let mut i = 0;
    while i < n {
        if stages[i] == 2 && epoch_mo[i] <= 1.0 {
            let mut j = i;
            while j < n && stages[j] == 2 && epoch_mo[j] <= 1.0 {
                j += 1;
            }
            if j - i >= 12 {
                runs.push((i, j));
            }
            i = j;
        } else {
            i += 1;
        }
    }
    if runs.is_empty() {
        return stages.to_vec();
    }
    let mut nrem_hrs: Vec<f64> = light_indices.iter().map(|&idx| sample_hr(idx)).collect();
    nrem_hrs.sort_by(|a, b| a.total_cmp(b));
    let hr_p25 = nrem_hrs[nrem_hrs.len() / 4];
    let hr_med = nrem_hrs[nrem_hrs.len() / 2];
    let hr_span = (nrem_hrs[3 * nrem_hrs.len() / 4] - hr_p25).max(2.0);

    let mut candidates: Vec<(f64, usize, usize)> = Vec::new();
    for (r_start, r_end) in runs {
        let mut cur = r_start;
        while cur + 10 <= r_end {
            let mut w_end = (cur + 20).min(r_end);
            if r_end - w_end < 10 {
                w_end = r_end;
            }
            let mean_hr: f64 =
                (cur..w_end).map(&sample_hr).sum::<f64>() / ((w_end - cur).max(1) as f64);
            let mid_frac = ((cur + w_end) as f64 / 2.0) / (n as f64);
            let homeo = 1.0 - 0.55 * mid_frac;
            let hr_score = (hr_med - mean_hr) / hr_span;
            let score = hr_score * 0.65 + homeo * 0.55;
            candidates.push((score, cur, w_end));
            cur = w_end;
        }
    }
    candidates.sort_by(|a, b| b.0.total_cmp(&a.0));
    let asleep_epochs = stages.iter().filter(|&&c| (1..=3).contains(&c)).count();
    let target_deep = ((asleep_epochs as f64) * 0.18).round() as usize;
    let min_deep = ((asleep_epochs as f64) * 0.10).round() as usize;
    let mut out = stages.to_vec();
    let mut deep_count = 0usize;
    for (score, s_idx, e_idx) in candidates {
        if deep_count >= target_deep {
            break;
        }
        if score < 0.05 && deep_count >= min_deep {
            break;
        }
        for cell in &mut out[s_idx..e_idx] {
            *cell = 1;
        }
        deep_count += e_idx - s_idx;
    }
    out
}

/// Estimate 30-second sleep stages (`1=DEEP, 2=LIGHT, 3=REM, 4=WAKE`) from a night's
/// physiological streams (`hr_t`, `hrv_t`, `motion_t`) when neither the proprietary
/// Torch model nor ring-side `sleep_phase_data` is available.
pub fn stage_night_from_signals(
    start_ds: i64,
    end_ds: i64,
    hr_t: &[(i64, f64)],
    hrv_t: &[(i64, f64)],
    motion_t: &[(i64, f64)],
) -> Vec<i64> {
    if end_ds <= start_ds || hr_t.len() < 12 {
        return Vec::new();
    }
    let epochs = ((end_ds - start_ds) / 300).max(1) as usize;
    if epochs < 120 {
        return Vec::new();
    }
    let span_ds = (end_ds - start_ds).max(1) as f64;
    let hr_vals: Vec<f64> = hr_t.iter().map(|&(_, v)| v).collect();
    let interp_hr = |idx: usize| -> f64 {
        let pos = idx as f64 / (epochs.saturating_sub(1).max(1) as f64)
            * (hr_vals.len().saturating_sub(1) as f64);
        let lo = (pos.floor() as usize).min(hr_vals.len() - 1);
        let hi = (lo + 1).min(hr_vals.len() - 1);
        let frac = pos - lo as f64;
        hr_vals[lo] * (1.0 - frac) + hr_vals[hi] * frac
    };
    let mut epoch_mo = vec![0.0f64; epochs];
    for &(ds, val) in motion_t {
        let f = ((ds - start_ds) as f64 / span_ds).clamp(0.0, 0.999_999);
        let idx = ((f * epochs as f64) as isize).clamp(0, epochs as isize - 1);
        for d in -1..=1 {
            let k = idx + d;
            if (0..epochs as isize).contains(&k) {
                let ku = k as usize;
                epoch_mo[ku] = epoch_mo[ku].max(val);
            }
        }
    }
    let mut sorted_hr = hr_vals.clone();
    sorted_hr.sort_by(|a, b| a.total_cmp(b));
    let hr_med = sorted_hr[sorted_hr.len() / 2];
    let hr_p75 = sorted_hr[3 * sorted_hr.len() / 4];

    let mut stages = vec![2i64; epochs];
    let mut onset = 0usize;
    let max_onset = (epochs / 4).min(120);
    for i in 0..max_onset {
        let end_chk = (i + 12).min(epochs);
        if (i..end_chk).all(|k| epoch_mo[k] <= 2.0) {
            onset = i;
            break;
        }
    }
    for cell in &mut stages[..onset] {
        *cell = 4;
    }
    let mut wake_end = epochs;
    let min_wake_end = onset.max(epochs.saturating_sub(60));
    for i in (min_wake_end..epochs).rev() {
        if epoch_mo[i] >= 3.0 || interp_hr(i) > hr_p75 {
            wake_end = i;
        } else {
            break;
        }
    }
    for cell in &mut stages[wake_end..epochs] {
        *cell = 4;
    }
    for i in onset..wake_end {
        if epoch_mo[i] >= 8.0 || (epoch_mo[i] >= 5.0 && interp_hr(i) >= hr_p75) {
            let lo = i.saturating_sub(2).max(onset);
            let hi = (i + 3).min(wake_end);
            for cell in &mut stages[lo..hi] {
                *cell = 4;
            }
        }
    }
    let rem_start = (onset + 120).min(wake_end);
    let rem_end = wake_end.saturating_sub(10).max(rem_start);
    let sleep_span = (wake_end.saturating_sub(onset)).max(1) as f64;
    for i in rem_start..rem_end {
        if stages[i] != 2 || epoch_mo[i] > 3.0 {
            continue;
        }
        let frac = (i - onset) as f64 / sleep_span;
        let cycle_pos = ((i - onset) % 180) as f64 / 180.0;
        let in_rem_phase = (0.62..=0.92).contains(&cycle_pos);
        if in_rem_phase && (frac >= 0.35 || interp_hr(i) >= hr_med - 0.5) && epoch_mo[i] <= 2.0 {
            stages[i] = 3;
        }
    }
    let _ = hrv_t;
    let refined = refine_deep_stages(&stages, hr_t, motion_t, start_ds, end_ds);
    smooth_stages(&refined, 5)
}

/// Fallback batch stager for desktop/CLI runs when the proprietary `.pt` model is
/// unavailable on the machine. Reads nocturnal `hrv_event` (`0x5d`) and `motion_event`
/// (`0x47`) streams from `db` and returns the same JSON batch shape as `run_sleep_model.py`.
pub fn stage_nights_from_signals(db: &Path, sleep_ranges: &[[i64; 3]]) -> Option<Value> {
    if sleep_ranges.is_empty() {
        return Some(Value::Array(Vec::new()));
    }
    let store = Store::open_read_only(db).ok()?;
    let events = store.decoded_events().ok()?;
    let mut results = Vec::with_capacity(sleep_ranges.len());
    for &[start_ds, end_ds, captured_unix] in sleep_ranges {
        let mut hr_t = Vec::new();
        let mut hrv_t = Vec::new();
        let mut motion_t = Vec::new();
        for (ds, tag, jstr, _cu) in &events {
            if *ds < start_ds - 600 || *ds > end_ds + 600 {
                continue;
            }
            if *tag == 0x5d {
                if let Ok(v) = serde_json::from_str::<Value>(jstr) {
                    let step_ds = v["interval_min"].as_i64().unwrap_or(5).max(1) * 600;
                    if let Some(a) = v["hr_bpm"].as_array() {
                        for (i, x) in a.iter().enumerate() {
                            if let Some(val) = x.as_f64().filter(|&v| v > 0.0) {
                                hr_t.push((*ds + i as i64 * step_ds, val));
                            }
                        }
                    }
                    if let Some(a) = v["rmssd_ms"].as_array() {
                        for (i, x) in a.iter().enumerate() {
                            if let Some(val) = x.as_f64().filter(|&v| v > 0.0) {
                                hrv_t.push((*ds + i as i64 * step_ds, val));
                            }
                        }
                    }
                }
            } else if *tag == 0x47 {
                if let Ok(v) = serde_json::from_str::<Value>(jstr) {
                    if let Some(s) = v["motion_seconds"].as_f64() {
                        motion_t.push((*ds, s));
                    }
                }
            }
        }
        hr_t.sort_by_key(|&(ds, _)| ds);
        hrv_t.sort_by_key(|&(ds, _)| ds);
        motion_t.sort_by_key(|&(ds, _)| ds);
        let stages = stage_night_from_signals(start_ds, end_ds, &hr_t, &hrv_t, &motion_t);
        if stages.is_empty() {
            results.push(Value::Null);
            continue;
        }
        let n = stages.len() as f64;
        let pct = |code: i64| (stages.iter().filter(|&&c| c == code).count() as f64 / n * 100.0).round();
        let asleep = stages.iter().filter(|&&c| (1..=3).contains(&c)).count() as f64;
        results.push(json!({
            "start_ds": start_ds,
            "end_ds": end_ds,
            "captured_unix": captured_unix,
            "epochs": stages.len(),
            "in_bed_min": n * 0.5,
            "asleep_min": asleep * 0.5,
            "efficiency_pct": (asleep / n * 100.0).round(),
            "deep_pct": pct(1),
            "light_pct": pct(2),
            "rem_pct": pct(3),
            "wake_pct": pct(4),
            "source": "signals",
            "stages": stages,
        }));
    }
    Some(Value::Array(results))
}

/// Nights the ring recorded but never declared.
///
/// `bedtime_period` is the ring's own verdict and is trusted first, but it is not
/// always complete: a Gen 3 (fw 3.4.3) declared a single **15-minute** bedtime period
/// for a night it went on to stage as 8.7 hours of sleep.
///
/// What fills the gap, in order of how much the ring is actually claiming:
///
/// 1. **An analysed sleep.** A `sleep_phase_data` run is the ring's own sleep period,
///    already staged epoch by epoch — the same thing Oura would call your night.
/// 2. **Failing that, a run of nocturnal events trimmed by `sleep_state`.** The
///    nocturnal streams switch on when the ring *starts measuring*, which is not when
///    you fell asleep: on the night in question they began at 20:37, while the ring's
///    own `sleep_state` stayed mostly 0 for two more hours with HR at 78 and the
///    accelerometer busy. Taking mere presence of those events as "in bed" produced a
///    10.7-hour night that was really 8.7 hours of sleep with two hours of television
///    in front of it. So a fallback run is trimmed to where the ring itself says you
///    were asleep, smoothed so one restless window cannot clip the night.
///
/// Either way a period must last [`MIN_DERIVED_BED_DS`] to count, which keeps an
/// evening doze from becoming a night, and derived periods go through the normal merge
/// so an explicit `bedtime_period` still wins where the ring gave one.
fn beds_from_sleep_signal(
    explicit: &[BedPeriod],
    ring_sleeps: &[RingSleep],
    sleep_support: &[(i64, i64)],
    sleep_state: &[(i64, i64)],
    unix_s_at: impl Fn(i64, i64) -> f64 + Copy,
) -> Vec<BedPeriod> {
    let mut derived: Vec<BedPeriod> = Vec::new();
    let covered = |start: i64, end: i64, derived: &[BedPeriod]| {
        explicit
            .iter()
            .chain(derived.iter())
            .any(|bed| bed.start_ds <= start && end <= bed.end_ds)
    };

    // 1. the ring's own analysed sleeps
    for run in ring_sleeps {
        if run.end_ds - run.start_ds < MIN_DERIVED_BED_DS
            || covered(run.start_ds, run.end_ds, &derived)
        {
            continue;
        }
        derived.push(BedPeriod {
            start_ds: run.start_ds,
            end_ds: run.end_ds,
            raw_start_ds: run.start_ds,
            raw_end_ds: run.end_ds,
            captured_unix: run.captured_unix,
            staged: true,
        });
    }

    // 2. nocturnal-signal runs, for a sleep the ring never staged
    if sleep_support.is_empty() {
        return derived;
    }
    let mut samples: Vec<(i64, i64)> = sleep_support.to_vec();
    samples.sort_by(|a, b| unix_s_at(a.0, a.1).total_cmp(&unix_s_at(b.0, b.1)));

    let mut runs: Vec<((i64, i64), (i64, i64))> = Vec::new();
    let mut run = (samples[0], samples[0]);
    for sample in samples.into_iter().skip(1) {
        let raw_gap_ds = sample.0 - run.1 .0;
        let wall_gap_s = unix_s_at(sample.0, sample.1) - unix_s_at(run.1 .0, run.1 .1);
        let same_epoch = (wall_gap_s - raw_gap_ds as f64 / 10.0).abs() <= EPOCH_ALIGNMENT_SLACK_S;
        if same_epoch && (0..=MAX_BED_BREAK_DS).contains(&raw_gap_ds) {
            run.1 = sample;
        } else {
            runs.push(run);
            run = (sample, sample);
        }
    }
    runs.push(run);

    for (start, end) in runs {
        // Where the ring staged a sleep inside this run, the staged sleep IS the
        // answer for that stretch — a fallback period spanning it would double the
        // night, and the longer of the two would swallow the HRV and pulse samples
        // that belong to the real one.
        if ring_sleeps
            .iter()
            .any(|run| run.start_ds < end.0 && start.0 < run.end_ds)
        {
            continue;
        }
        let Some((asleep_from, asleep_to)) = asleep_span(&sleep_state, start.0, end.0) else {
            continue;
        };
        if asleep_to - asleep_from < MIN_DERIVED_BED_DS || covered(asleep_from, asleep_to, &derived)
        {
            continue;
        }
        derived.push(BedPeriod {
            start_ds: asleep_from,
            end_ds: asleep_to,
            raw_start_ds: asleep_from,
            raw_end_ds: asleep_to,
            captured_unix: end.1,
            staged: false,
        });
    }
    derived
}

/// How many windows either side must agree before the ring's `sleep_state` is believed
/// to have turned over. ~5 windows ≈ 3 min at the observed cadence: long enough that a
/// single restless minute neither starts nor ends a night.
const SLEEP_STATE_SMOOTHING: usize = 5;

/// The stretches the ring itself calls sleep, smoothed by [`SLEEP_STATE_SMOOTHING`].
/// Empty when the ring never reported a state, which is the signal to fall back to
/// plain presence of the nocturnal streams.
fn asleep_regions(sleep_state: &[(i64, i64)]) -> Vec<(i64, i64)> {
    if sleep_state.len() < SLEEP_STATE_SMOOTHING {
        return Vec::new();
    }
    let asleep_at = |i: usize| -> bool {
        let lo = i.saturating_sub(SLEEP_STATE_SMOOTHING / 2);
        let hi = (i + SLEEP_STATE_SMOOTHING / 2 + 1).min(sleep_state.len());
        let slice = &sleep_state[lo..hi];
        slice.iter().filter(|(_, state)| *state == 1).count() * 2 > slice.len()
    };
    let mut regions: Vec<(i64, i64)> = Vec::new();
    for i in 0..sleep_state.len() {
        if !asleep_at(i) {
            continue;
        }
        let at = sleep_state[i].0;
        match regions.last_mut() {
            Some(region) if at - region.1 <= MAX_BED_BREAK_DS => region.1 = at,
            _ => regions.push((at, at)),
        }
    }
    regions
}

/// First and last moment inside `[from_ds, to_ds]` where the ring's own `sleep_state`
/// says you were asleep, smoothed by [`SLEEP_STATE_SMOOTHING`]. `None` when the ring
/// never called it sleep.
fn asleep_span(sleep_state: &[(i64, i64)], from_ds: i64, to_ds: i64) -> Option<(i64, i64)> {
    let window: Vec<(i64, i64)> = sleep_state
        .iter()
        .copied()
        .filter(|(ds, _)| (from_ds..=to_ds).contains(ds))
        .collect();
    if window.len() < SLEEP_STATE_SMOOTHING {
        return None;
    }
    let asleep_at = |i: usize| -> bool {
        let lo = i.saturating_sub(SLEEP_STATE_SMOOTHING / 2);
        let hi = (i + SLEEP_STATE_SMOOTHING / 2 + 1).min(window.len());
        let slice = &window[lo..hi];
        slice.iter().filter(|(_, state)| *state == 1).count() * 2 > slice.len()
    };
    let first = (0..window.len()).find(|&i| asleep_at(i))?;
    let last = (0..window.len()).rev().find(|&i| asleep_at(i))?;
    (last > first).then(|| (window[first].0, window[last].0))
}

fn normalize_bed_periods(
    mut periods: Vec<BedPeriod>,
    sleep_support: &[(i64, i64)],
    pulse_support: &[(i64, i64, usize)],
    sleep_state: &[(i64, i64)],
    unix_s_at: impl Fn(i64, i64) -> f64 + Copy,
) -> Vec<BedPeriod> {
    periods.sort_by(|a, b| {
        unix_s_at(a.start_ds, a.captured_unix).total_cmp(&unix_s_at(b.start_ds, b.captured_unix))
    });

    let asleep = asleep_regions(sleep_state);
    // Merging exists to rejoin a night the ring broke at a brief awakening. A gap it
    // labels awake from end to end is not that: it is getting up. Without this, an
    // evening doze and the real night an hour later become one 10-hour "night".
    let awake_throughout = |from: i64, to: i64| {
        !asleep.is_empty()
            && to > from
            && !asleep.iter().any(|(start, end)| *start < to && from < *end)
    };

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
                && !awake_throughout(previous.end_ds, period.start_ds)
            {
                previous.end_ds = previous.end_ds.max(period.end_ds);
                previous.raw_start_ds = previous.raw_start_ds.min(period.raw_start_ds);
                previous.raw_end_ds = previous.raw_end_ds.max(period.raw_end_ds);
                previous.captured_unix = previous.captured_unix.max(period.captured_unix);
                previous.staged |= period.staged;
            } else {
                merged.push(period);
            }
        }
        merged
    };

    // Where the ring staged a sleep, that sleep's start is a wall the extension below
    // must not climb over: a 15-minute declared bedtime followed by 3 hours of
    // "extension" would otherwise swallow the real night that begins after it, and
    // report an evening on the sofa as time in bed.
    let staged_starts: Vec<i64> = periods
        .iter()
        .filter(|bed| bed.staged)
        .map(|bed| bed.start_ds)
        .collect();

    let mut periods = merge_adjacent(periods);
    for period in &mut periods {
        if period.staged {
            continue;
        }
        let original_end = period.end_ds;
        let end_unix = unix_s_at(original_end, period.captured_unix);
        let wall = staged_starts
            .iter()
            .copied()
            .filter(|start| *start > original_end)
            .min()
            .unwrap_or(i64::MAX);
        let mut continuation: Vec<i64> = Vec::new();
        for &(support_ds, support_captured) in sleep_support {
            let raw_delta_ds = support_ds - original_end;
            if !(0..=MAX_SLEEP_SIGNAL_EXTENSION_DS).contains(&raw_delta_ds) || support_ds > wall {
                continue;
            }
            // A nocturnal event only means the ring was measuring. Where the ring also
            // reports a state, an extension has to land somewhere it calls sleep —
            // otherwise a 15-minute declared bedtime grows through an evening of
            // television and swallows the real night behind it.
            if !asleep.is_empty()
                && !asleep
                    .iter()
                    .any(|(from, to)| (*from..=*to).contains(&support_ds))
            {
                continue;
            }
            let wall_delta_s = unix_s_at(support_ds, support_captured) - end_unix;
            let same_epoch =
                (wall_delta_s - raw_delta_ds as f64 / 10.0).abs() <= EPOCH_ALIGNMENT_SLACK_S;
            if same_epoch
                && (0.0..=MAX_SLEEP_SIGNAL_EXTENSION_DS as f64 / 10.0).contains(&wall_delta_s)
            {
                continuation.push(support_ds);
            }
        }
        // Only sleep signals that keep coming carry the night on: walk them in time order
        // from the declared end and stop at the first silence longer than
        // MAX_SLEEP_SUPPORT_GAP_DS. Rings that report no sleep_state have no other guard
        // against a still spell hours after waking.
        continuation.sort_unstable();
        for support_ds in continuation {
            if support_ds - period.end_ds > MAX_SLEEP_SUPPORT_GAP_DS {
                break;
            }
            period.end_ds = period.end_ds.max(support_ds);
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
    if n == 0 || stages.iter().any(|c| !(1..=4).contains(c)) {
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
            if vals[i] == 0 {
                return 0;
            }
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

/// `[unix_s, percent]` battery readings, oldest first, limited to the `days` before the
/// newest one so the payload can't grow without bound. The ring reports a level roughly
/// every 10-60 min (`debug_data.battery_level_changed`), so a fortnight is a few hundred
/// points. Charging shows as the percentage rising; no flag is needed to see it.
fn battery_history(readings: &[(f64, i64)], days: i64) -> Vec<[f64; 2]> {
    let mut out: Vec<[f64; 2]> = readings.iter().map(|&(at, pct)| [at, pct as f64]).collect();
    out.sort_by(|a, b| a[0].total_cmp(&b[0]));
    if let Some(newest) = out.last().map(|p| p[0]) {
        let cut = newest - (days * 86_400) as f64;
        out.retain(|p| p[0] >= cut);
    }
    out
}

/// Time-true `[unix_s, value]` points for a night lane: the `(time_ds, value)` samples
/// inside `[start_ds, end_ds]`, bucketed into at most `max` equal-time buckets (means
/// of time and value) and rounded to `dp` decimals. Dense streams stay compact, sparse
/// ones keep their real times, and a stretch with no samples stays a gap — unlike the
/// flat `series`, which clients spread evenly over the night.
fn timed_series(
    samples: &[(i64, f64)],
    start_ds: i64,
    end_ds: i64,
    max: usize,
    dp: i32,
    to_unix: impl Fn(i64) -> f64,
) -> Vec<[f64; 2]> {
    let span = (end_ds - start_ds).max(1) as i128;
    let len = max.max(1);
    let mut buckets = vec![(0.0f64, 0.0f64, 0u32); len];
    for &(ds, v) in samples {
        if ds < start_ds || ds > end_ds {
            continue;
        }
        // integer bucket index: a sample on a bucket boundary must not drift into the
        // neighbour through float rounding
        let i = ((ds - start_ds) as i128 * len as i128 / span) as usize;
        let b = &mut buckets[i.min(len - 1)];
        b.0 += ds as f64;
        b.1 += v;
        b.2 += 1;
    }
    let m = 10f64.powi(dp);
    buckets
        .iter()
        .filter(|b| b.2 > 0)
        .map(|b| {
            let n = b.2 as f64;
            [
                to_unix((b.0 / n).round() as i64).round(),
                ((b.1 / n) * m).round() / m,
            ]
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
            if slice.contains(&0) {
                0
            } else {
                (1..=4).max_by_key(|&k| counts[k as usize]).unwrap_or(2) as i64
            }
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
pub fn build_summary(
    db: &Path,
    tz: impl Into<OffsetHours>,
    runner: &dyn ModelRunner,
) -> Result<Value> {
    let tz = tz.into().0;
    anyhow::ensure!(
        tz.is_finite() && (-24.0..=24.0).contains(&tz),
        "invalid UTC offset"
    );
    let db_abs = std::fs::canonicalize(db).unwrap_or_else(|_| {
        std::env::current_dir()
            .map(|d| d.join(db))
            .unwrap_or_else(|_| db.to_path_buf())
    });
    let db = db_abs.as_path();
    let demo = read_profile(db);
    let _ = Store::migrate_if_writable(db);
    let store = Store::open_read_only(db).context("opening DB")?;
    let events = store.decoded_events().context("reading events")?;
    if events.is_empty() {
        return Err(anyhow!(
            "no decoded events in {} — run `oura sync` first",
            db.display()
        ));
    }
    let (raw_events_total, decoded_events_total) = store
        .event_totals()
        .unwrap_or((events.len(), events.len()));
    let clock = RingClock::from_events(&events);
    let history_stats = clock.trusted_history_stats(&events, tz);
    let unix_s_at = |ds: i64, captured_unix: i64| clock.unix_s(ds, captured_unix);
    // An event whose boot clock cannot be trusted has no calendar day; feeding it to
    // the aggregations would scatter it over fabricated dates (a fresh ring's first
    // days used to produce months of phantom history). Bedtime markers are still
    // collected so those nights are reported as undated instead of vanishing.
    let is_dated = |ds: i64, captured_unix: i64| {
        clock.resolve(ds, captured_unix).source != ring_time::ClockSource::Undated
    };
    let anchor_unix = clock.latest_unix();
    let mut raw_beds: Vec<BedPeriod> = Vec::new();
    let mut sleep_support: Vec<(i64, i64)> = Vec::new();
    let mut ring_hypnogram_pages: Vec<(i64, i64, i64, Vec<i64>)> = Vec::new();
    // (ds, sleep_state) straight from the ring: its own asleep/awake call per window.
    let mut ring_sleep_state: Vec<(i64, i64)> = Vec::new();
    let mut pulse_support: Vec<(i64, i64, usize)> = Vec::new();
    let mut latest_hr: Option<(f64, f64)> = None; // (wall-clock unix, bpm)
    let mut present_recent = std::collections::HashSet::new();
    // "recent" = within 10 days of the newest data, measured in wall-clock so it never
    // sweeps in an older epoch that happens to share a high raw ds.
    let recent_cut_unix = anchor_unix as f64 - 10.0 * 86_400.0;
    let name_of = |tag: u8| oura_protocol::events::event_name(tag);
    for (ds, tag, jstr, cu) in &events {
        let n = name_of(*tag);
        let dated = is_dated(*ds, *cu);
        if dated && unix_s_at(*ds, *cu) >= recent_cut_unix {
            present_recent.insert(n);
        }
        if !dated && n != "bedtime_period" {
            continue;
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
                            staged: false,
                        }),
                    }
                }
            }
        }
        if n == "sleep_phase_data" {
            if let Ok(v) = serde_json::from_str::<Value>(jstr) {
                if let (Some(page), Some(phases)) = (v["header"].as_i64(), v["phases"].as_array()) {
                    ring_hypnogram_pages.push((
                        *ds,
                        *cu,
                        page,
                        phases
                            .iter()
                            .filter_map(|p| p.as_str().map(stage_code))
                            .collect::<Vec<i64>>(),
                    ));
                }
            }
        }
        if matches!(
            n,
            "sleep_acm_period"
                | "sleep_temp_event"
                | "spo2_r_pi_event"
                | "sleep_period_information_2"
        ) {
            sleep_support.push((*ds, *cu));
        }
        if n == "sleep_period_information_2" {
            if let Ok(v) = serde_json::from_str::<Value>(jstr) {
                if let Some(state) = v["sleep_state"].as_i64() {
                    ring_sleep_state.push((*ds, state));
                }
            }
        }
        // Both SleepNet implementations already consume these two streams. `hr_bpm`
        // is populated only when the firmware accepted a pulse estimate, so it is a
        // stronger continuation signal than raw/invalid IBI values.
        if matches!(n, "ibi_and_amplitude_event" | "green_ibi_quality_event") {
            if let Ok(v) = serde_json::from_str::<Value>(jstr) {
                if let Some(accepted) = v["hr_bpm"].as_array().map(Vec::len).filter(|&n| n > 0) {
                    pulse_support.push((*ds, *cu, accepted));
                }
                // `green_ibi_quality_event.hr_bpm` contains only pulse estimates the
                // firmware's quality gate accepted. Surface its newest value as the
                // latest synchronized HR; raw IBI-derived values are too noisy for a
                // user-facing "current" measurement.
                if n == "green_ibi_quality_event" {
                    if let Some(bpm) = v["hr_bpm"]
                        .as_array()
                        .and_then(|values| values.iter().rev().find_map(Value::as_f64))
                        .filter(|bpm| (30.0..=240.0).contains(bpm))
                    {
                        let at = unix_s_at(*ds, *cu);
                        if latest_hr.map_or(true, |(current, _)| at > current) {
                            latest_hr = Some((at, bpm));
                        }
                    }
                }
            }
        }
    }
    let ring_sleeps = ring_sleep_runs(&ring_hypnogram_pages);
    raw_beds.extend(beds_from_sleep_signal(
        &raw_beds,
        &ring_sleeps,
        &sleep_support,
        &ring_sleep_state,
        unix_s_at,
    ));
    let beds = normalize_bed_periods(
        raw_beds,
        &sleep_support,
        &pulse_support,
        &ring_sleep_state,
        unix_s_at,
    );
    // A night whose boot clock is untrustworthy cannot be placed on the calendar.
    // Record the specific clock reason (`missing_anchor`, `accelerated_counter`, or
    // `ambiguous_reboot_stall`) and whether a future sync can recover it.
    let mut undated_nights: Vec<Value> = Vec::new();
    let mut undated_reason_counts: std::collections::BTreeMap<(ring_time::UndatedReason, bool), usize> =
        std::collections::BTreeMap::new();
    let beds: Vec<BedPeriod> = beds
        .into_iter()
        .filter(|bed| {
            let start = clock.resolve(bed.start_ds, bed.captured_unix);
            let end = clock.resolve(bed.end_ds, bed.captured_unix);
            if start.source.is_dated() && end.source.is_dated() {
                return true;
            }
            let reason = end
                .undated_reason
                .or(start.undated_reason)
                .unwrap_or(ring_time::UndatedReason::MissingAnchor);
            let is_latest_unanchored =
                clock.is_in_latest_unanchored_epoch(bed.end_ds, bed.captured_unix);
            let recoverable = reason.is_recoverable_by_sync(is_latest_unanchored);
            *undated_reason_counts.entry((reason, recoverable)).or_default() += 1;
            undated_nights.push(json!({
                "start_ds": bed.start_ds,
                "end_ds": bed.end_ds,
                "in_bed_h": ((bed.end_ds - bed.start_ds) as f64 / 36_000.0 * 10.0).round() / 10.0,
                "captured_unix": bed.captured_unix,
                "source": end.source.label(),
                "reason": reason.code(),
                "recoverable": recoverable,
            }));
            false
        })
        .collect();

    let bedtime_overrides = read_bedtime_overrides(db);
    let mut nights: Vec<Night> = beds
        .iter()
        .map(|bed| {
            let mut nt = Night {
                start_ds: bed.start_ds,
                end_ds: bed.end_ds,
                raw_start_ds: bed.raw_start_ds,
                raw_end_ds: bed.raw_end_ds,
                captured_unix: bed.captured_unix,
                ..Default::default()
            };
            let key_cu = format!("{}:{}", bed.raw_start_ds, bed.captured_unix);
            let key_raw = format!("{}", bed.raw_start_ds);
            let key_start_cu = format!("{}:{}", bed.start_ds, bed.captured_unix);
            let key_start = format!("{}", bed.start_ds);
            if let Some(ov) = bedtime_overrides
                .get(&key_cu)
                .or_else(|| bedtime_overrides.get(&key_raw))
                .or_else(|| bedtime_overrides.get(&key_start_cu))
                .or_else(|| bedtime_overrides.get(&key_start))
            {
                nt.start_ds = ov.start_ds;
                nt.end_ds = ov.end_ds;
                nt.manual_bedtime = true;
            }
            nt
        })
        .collect();
    let find_night = |ds: i64, captured_unix: i64, nights: &[Night]| {
        nights
            .iter()
            .enumerate()
            .filter(|(_, nt)| {
                nt.start_ds - 600 <= ds
                    && ds <= nt.end_ds + 600
                    && (unix_s_at(ds, captured_unix) - unix_s_at(ds, nt.captured_unix)).abs()
                        <= EPOCH_ALIGNMENT_SLACK_S
            })
            .min_by_key(|(_, nt)| (nt.captured_unix - captured_unix).abs())
            .map(|(idx, _)| idx)
    };
    for (ds, tag, jstr, cu) in &events {
        if !is_dated(*ds, *cu) {
            continue;
        }
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
            "sleep_period_information_2" => {
                // The ring's own per-window sleep sample. Breathing while awake is
                // faster and more variable, so only sleep windows count.
                if v["sleep_state"].as_i64() == Some(1) {
                    if let Some(breath) = v["breath"].as_f64() {
                        if (4.0..=40.0).contains(&breath) {
                            nights[idx].breath.push(breath);
                        }
                    }
                }
            }
            "sleep_temp_event" => {
                // Only the dedicated nocturnal stream is calibrated as skin
                // temperature. Generic `temp_event` contains several device/ambient
                // channels; mixing it here creates a false plunge when sleep mode ends.
                if let Some(a) = v["temps_c"].as_array() {
                    let temps: Vec<f64> = a
                        .iter()
                        .filter_map(|x| x.as_f64())
                        .filter(|&c| c > 0.0)
                        .collect();
                    nights[idx].temp_t.extend(temps.iter().map(|&c| (*ds, c)));
                    nights[idx].temp.extend(temps);
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
                    let pcts: Vec<f64> = a
                        .iter()
                        .filter_map(|x| x.as_f64())
                        .filter(|&x| x > 0.0)
                        .map(spo2_pct)
                        .collect();
                    nights[idx].spo2_t.extend(pcts.iter().map(|&p| (*ds, p)));
                    nights[idx].spo2.extend(pcts);
                }
            }
            "motion_event" => {
                // seconds of motion in this window — a restlessness signal aligned to
                // the night, feeds the polysomnograph's movement lane.
                if let Some(s) = v["motion_seconds"].as_f64() {
                    nights[idx].motion.push(s);
                    nights[idx].motion_t.push((*ds, s));
                }
            }
            _ => {}
        }
    }

    // the model seam — sleep / cva / activity (Python subprocess or on-device .ptl)
    let sleep_ranges: Vec<[i64; 3]> = nights
        .iter()
        .map(|nt| [nt.start_ds, nt.end_ds, nt.captured_unix])
        .collect();
    let ModelOutputs {
        sleep_batch,
        cva,
        activity: activity_raw,
        illness,
    } = runner.run(ModelInputs {
        db,
        tz,
        demo: &demo,
        sleep_ranges: &sleep_ranges,
    });

    let mut hyps: std::collections::HashMap<(i64, i64), Value> = sleep_batch
        .as_ref()
        .and_then(|v| v.as_array())
        .map(|arr| {
            arr.iter()
                .filter_map(|h| {
                    let start = h["start_ds"].as_i64()?;
                    let captured = h["captured_unix"].as_i64().or_else(|| {
                        nights
                            .iter()
                            .find(|nt| nt.start_ds == start)
                            .map(|nt| nt.captured_unix)
                    })?;
                    Some(((start, captured), h.clone()))
                })
                .collect()
        })
        .unwrap_or_default();
    // The ring scores its own hypnogram; use it for any night the model runner did not
    // cover — which, in a model-free build, is every night.
    for (start_ds, hypnogram) in ring_hypnograms(&ring_sleeps, &nights, unix_s_at) {
        hyps.entry(start_ds).or_insert(hypnogram);
    }

    nights.sort_by(|a, b| {
        unix_s_at(a.start_ds, a.captured_unix)
            .total_cmp(&unix_s_at(b.start_ds, b.captured_unix))
            .then_with(|| {
                unix_s_at(a.end_ds, a.captured_unix)
                    .total_cmp(&unix_s_at(b.end_ds, b.captured_unix))
            })
    });

    // downsample a raw signal to ≤N points (bucket mean) then round for a compact
    // payload. Clients spread `series` evenly across the night window, which is only
    // right when a signal covers the whole night; a stream that stops early (the 5-min
    // HR averages end once you wake) gets stretched. `series_t` carries real times.
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
    let mut incomplete_sleep_days = std::collections::BTreeSet::new();
    // (wake date, biomarkers) per night, oldest first — the Symptom Radar input.
    let mut nightly_biomarkers: Vec<(String, symptoms::NightBiomarkers)> = Vec::new();
    // Causal personal baselines for the sleep score's physiology component: for each
    // main sleep (>= MIN_BASELINE_SLEEP_DS), only strictly preceding main-sleep nights
    // (`end_unix <= start_unix`) in resolved chronological order may contribute. Naps
    // and undated/ambiguous windows are excluded, and fewer than MIN_BASELINE_NIGHTS
    // prior observations yields `None` so `score_night` explicitly renormalizes without
    // self-inclusion or future-data leakage.
    let mut prior_main_rhr: Vec<(f64, f64)> = Vec::new();
    let mut prior_main_hrv: Vec<(f64, f64)> = Vec::new();
    for nt in &nights {
        let hyp = hyps.get(&(nt.start_ds, nt.captured_unix));
        let raw_stages: Vec<i64> = hyp
            .and_then(|h| h["stages"].as_array())
            .map(|s| s.iter().filter_map(|x| x.as_i64()).collect())
            .unwrap_or_default();
        // smooth once (≈2.5 min window) — used for the displayed hypnogram AND the
        // derived metrics, so the two always agree.
        let mut full_stages = smooth_stages(&raw_stages, 5);
        if !full_stages.is_empty()
            && !full_stages.contains(&1)
            && hyp.and_then(|h| h["deep_pct"].as_f64()).unwrap_or(0.0) == 0.0
            && nt.hr_t.len() >= 12
        {
            full_stages = refine_deep_stages(
                &full_stages,
                &nt.hr_t,
                &nt.motion_t,
                nt.start_ds,
                nt.end_ds,
            );
        }
        let valid_stage_count = full_stages.iter().filter(|c| (1..=4).contains(*c)).count();
        let (deep_pct_val, light_pct_val, rem_pct_val, wake_pct_val) = if valid_stage_count > 0
            && full_stages.contains(&1)
            && hyp.and_then(|h| h["deep_pct"].as_f64()).unwrap_or(0.0) == 0.0
        {
            let pct_of = |code: i64| -> Value {
                let c = full_stages.iter().filter(|&&x| x == code).count();
                json!(((c as f64 / valid_stage_count as f64) * 100.0).round() as i64)
            };
            (pct_of(1), pct_of(2), pct_of(3), pct_of(4))
        } else {
            (
                hyp.map(|h| h["deep_pct"].clone()).unwrap_or(Value::Null),
                hyp.map(|h| h["light_pct"].clone()).unwrap_or(Value::Null),
                hyp.map(|h| h["rem_pct"].clone()).unwrap_or(Value::Null),
                hyp.map(|h| h["wake_pct"].clone()).unwrap_or(Value::Null),
            )
        };
        let stage_cells = (!full_stages.is_empty()).then(|| downsample_codes(&full_stages, 120));
        let complete_staging =
            !full_stages.is_empty() && full_stages.iter().all(|c| (1..=4).contains(c));
        let coverage_pct = (!full_stages.is_empty()).then(|| {
            full_stages.iter().filter(|c| (1..=4).contains(*c)).count() as f64
                / full_stages.len() as f64
                * 100.0
        });
        let in_bed_s = (nt.end_ds - nt.start_ds) as f64 / 10.0;
        let (metrics, asleep_s) = sleep_metrics(&full_stages, in_bed_s);
        let autonomic =
            autonomic_by_stage(&nt.hrv_t, &nt.hr_t, &full_stages, nt.start_ds, nt.end_ds);
        let start_unix = unix_s_at(nt.start_ds, nt.captured_unix);
        let end_unix = unix_s_at(nt.end_ds, nt.captured_unix);
        let raw_start_unix = unix_s_at(nt.raw_start_ds, nt.captured_unix);
        let raw_end_unix = unix_s_at(nt.raw_end_ds, nt.captured_unix);
        // time-true lane points on this night's clock (see `timed_series`)
        let timed = |v: &[(i64, f64)], dp: i32| {
            timed_series(v, nt.start_ds, nt.end_ds, SERIES_MAX, dp, |ds| {
                unix_s_at(ds, nt.captured_unix)
            })
        };
        let span_ds = (nt.end_ds - nt.start_ds).max(1) as f64;
        let temp_span = match (nt.temp_start_ds, nt.temp_end_ds) {
            (Some(start), Some(end)) => Some([
                ((start - nt.start_ds) as f64 / span_ds).clamp(0.0, 1.0),
                ((end - nt.start_ds) as f64 / span_ds).clamp(0.0, 1.0),
            ]),
            _ => None,
        };
        if !complete_staging {
            incomplete_sleep_days.insert((end_unix as i64 + offset_seconds(tz)).div_euclid(86_400));
        }
        if asleep_s > 0 {
            let wake_day = (end_unix as i64 + offset_seconds(tz)).div_euclid(86_400);
            *asleep_by_day.entry(wake_day).or_default() += asleep_s;
        }
        let raw_lowest_hr = {
            let lowest = nt.hr.iter().cloned().fold(f64::INFINITY, f64::min);
            lowest.is_finite().then_some(lowest)
        };
        let raw_mean_hrv = mean(&nt.rmssd);
        let night_rhr = raw_lowest_hr.map(|x| x.round());
        let night_hrv = raw_mean_hrv.map(|x| x.round());
        let night_breath = median_of(&nt.breath);
        let is_main_sleep = (nt.end_ds - nt.start_ds) >= sleep_score::MIN_BASELINE_SLEEP_DS;
        let rhr_baseline = if is_main_sleep {
            let priors: Vec<f64> = prior_main_rhr
                .iter()
                .filter(|&&(prev_end, _)| prev_end <= start_unix)
                .map(|&(_, v)| v)
                .collect();
            sleep_score::causal_baseline(&priors)
        } else {
            None
        };
        let hrv_baseline = if is_main_sleep {
            let priors: Vec<f64> = prior_main_hrv
                .iter()
                .filter(|&&(prev_end, _)| prev_end <= start_unix)
                .map(|&(_, v)| v)
                .collect();
            sleep_score::causal_baseline(&priors)
        } else {
            None
        };
        let wake_ymd = Some(ymd_label(end_unix, tz));
        nights_json.push(json!({
            "date": date_label(start_unix, tz),
            "ymd": ymd_label(start_unix, tz),
            // The morning you woke up: what the apps group a night under. Computed
            // here so the clients never have to guess it from the clock strings.
            "wake_ymd": ymd_label(end_unix, tz),
            "start_unix": start_unix.round() as i64,
            "end_unix": end_unix.round() as i64,
            "clock_source": clock.resolve(nt.end_ds, nt.captured_unix).source.label(),
            "start_ds": nt.start_ds, // exact bedtime key for on-device model injection
            "end_ds": nt.end_ds,
            // Android's interim schema likewise preserves bedtime_start/end_original
            // beside detector-adjusted bounds. Keep both for audits and future models.
            "raw_start_ds": nt.raw_start_ds,
            "raw_end_ds": nt.raw_end_ds,
            "bedtime_adjusted": nt.start_ds != nt.raw_start_ds || nt.end_ds != nt.raw_end_ds,
            "bedtime_manual": nt.manual_bedtime,
            "raw_start": hm(raw_start_unix, tz),
            "raw_end": hm(raw_end_unix, tz),
            "start": hm(start_unix, tz),
            "end": hm(end_unix, tz),
            "in_bed_h": ((nt.end_ds - nt.start_ds) as f64 / 10.0 / 3600.0 * 10.0).round() / 10.0,
            "hrv_ms": night_hrv,
            "rhr": night_rhr,
            "skin_temp": nightly_skin_temp(&nt.temp).map(|x| (x * 10.0).round() / 10.0),
            "spo2_mean": mean(&nt.spo2).map(|x| x.round()),
            "deep_pct": deep_pct_val,
            "light_pct": light_pct_val,
            "rem_pct": rem_pct_val,
            "wake_pct": wake_pct_val,
            "efficiency": hyp.map(|h| h["efficiency_pct"].clone()),
            "stages": stage_cells,
            "staging_source": hyp.and_then(|h| h["source"].as_str()),
            "staging_coverage_pct": coverage_pct,
            "staging_complete": complete_staging,
            "captured_unix": nt.captured_unix,
            // full-resolution hypnogram + aligned raw signals for the detail page's
            // stacked polysomnograph (empty arrays stay out of the way when absent).
            "stages_full": (!full_stages.is_empty()).then_some(full_stages),
            "series": {
                "hr": series(&nt.hr, 0),
                "hrv": series(&nt.rmssd, 0),
                "temp": series(&nt.temp, 2),
                "temp_span": temp_span,
                "spo2": series(&nt.spo2, 0),
                "motion": nt.motion,
                "motion_time": nt.motion_t.iter().map(|(ds, _)|
                    ((*ds - nt.start_ds) as f64 / span_ds).clamp(0.0, 1.0)).collect::<Vec<_>>(),
            },
            // the same lanes as time-true [unix_s, value] points (gaps stay gaps), for
            // charts that share a time axis; `series` above keeps its iOS contract
            "series_t": {
                "hr": timed(&nt.hr_t, 0),
                "hrv": timed(&nt.hrv_t, 0),
                "temp": timed(&nt.temp_t, 2),
                "spo2": timed(&nt.spo2_t, 0),
                "motion": timed(&nt.motion_t, 0),
            },
            "metrics": metrics,
            // mean HR/HRV per sleep stage (deep/light/rem) — deep-sleep HRV is the
            // recovery-relevant number; null when there's no hypnogram.
            "autonomic": autonomic,
            // A score whose every threshold traces to a paper rather than to a fit
            // against Oura's own number. See `sleep_score`.
            "sleep_score": if complete_staging { sleep_score::score_night(sleep_score::NightInput {
                asleep_min: (asleep_s > 0).then(|| asleep_s as f64 / 60.0),
                efficiency_pct: hyp.and_then(|h| h["efficiency_pct"].as_f64()),
                onset_latency_min: metrics["sol_min"].as_f64(),
                waso_min: metrics["waso_min"].as_f64(),
                awakenings: metrics["awakenings"].as_f64(),
                deep_pct: deep_pct_val.as_f64(),
                rem_pct: rem_pct_val.as_f64(),
                rhr: night_rhr,
                rhr_baseline,
                hrv_ms: night_hrv,
                hrv_baseline,
                age: demo.age,
            }) } else { Value::Null },
            "breath_rate": night_breath.map(|b| (b * 10.0).round() / 10.0),
        }));
        if is_main_sleep {
            if let Some(lowest) = raw_lowest_hr {
                prior_main_rhr.push((end_unix, lowest));
            }
            if let Some(hrv_mean) = raw_mean_hrv {
                prior_main_hrv.push((end_unix, hrv_mean));
            }
        }
        if let Some(day) = wake_ymd.clone() {
            nightly_biomarkers.push((
                day,
                symptoms::NightBiomarkers {
                    skin_temp: nightly_skin_temp(&nt.temp),
                    lowest_hr: night_rhr,
                    hrv_ms: night_hrv,
                    breath_rate: night_breath,
                },
            ));
        }
    }
    nights_json.reverse();

    asleep_by_day.retain(|day, _| !incomplete_sleep_days.contains(day));
    let sleep_debt = sleep_debt_summary(&asleep_by_day);

    // Symptom signs for the most recent night, judged against the nights before it.
    // `nights` is oldest-first, so the last entry is tonight and everything before it
    // is the baseline — tonight is deliberately excluded from its own comparison.
    let symptoms = match nightly_biomarkers.split_last() {
        Some(((date, tonight), history)) => {
            let history: Vec<symptoms::NightBiomarkers> =
                history.iter().map(|(_, marks)| *marks).collect();
            symptoms::symptom_signs(*tonight, &history, date)
        }
        None => Value::Null,
    };

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
        if !is_dated(*ds, *cu) {
            continue;
        }
        if let Ok(v) = serde_json::from_str::<Value>(jstr) {
            if let Some(met) = v["met"].as_array() {
                for (i, m) in met.iter().enumerate() {
                    let mv = m.as_f64().unwrap_or(1.0);
                    let unix = unix_s_at(*ds, *cu) + i as f64 * 60.0;
                    let local = unix + tz * 3600.0;
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
    let mut battery_readings: Vec<(f64, i64)> = Vec::new();
    for (ds, tag, jstr, cu) in &events {
        if name_of(*tag) == "debug_data" && jstr.contains("battery_pct") {
            if let Ok(v) = serde_json::from_str::<Value>(jstr) {
                if let Some(p) = v["battery_pct"].as_i64() {
                    battery = Some((p, v["voltage_mv"].as_i64().unwrap_or(0)));
                    if (0..=100).contains(&p) && is_dated(*ds, *cu) {
                        battery_readings.push((unix_s_at(*ds, *cu), p));
                    }
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
        "days_of_data": history_stats.elapsed_days,
        "elapsed_days": history_stats.elapsed_days,
        "observed_days": history_stats.observed_days,
        "observed_coverage_days": history_stats.observed_coverage_days,
        "total_events": raw_events_total,
        "raw_events": raw_events_total,
        "decoded_events": decoded_events_total,
        "nights": nights.len(),
        "battery_pct": battery.map(|b| b.0),
        "battery_v": battery.map(|b| (b.1 as f64 / 1000.0 * 100.0).round() / 100.0),
        // [unix_s, percent] readings for the battery chart; see `battery_history`
        "battery_history": battery_history(&battery_readings, BATTERY_HISTORY_DAYS),
        "measuring": measuring,
        "streams": streams,
        "event_counts": event_counts,
        "next_cursor": dev.as_ref().map(|d| d.7),
        "insights": insights,
    });

    let digest = make_digest(&hrv_stat, &rhr_stat);

    let mut clock_diag = clock.diagnostics();
    clock_diag["undated_nights"] = json!(undated_nights);
    let mut clock_warnings: Vec<String> = Vec::new();
    let mut undated_reasons_json: Vec<Value> = Vec::new();
    for ((reason, recoverable), count) in &undated_reason_counts {
        let message = reason.warning_message(*count, *recoverable);
        clock_warnings.push(message.clone());
        undated_reasons_json.push(json!({
            "reason": reason.code(),
            "count": count,
            "recoverable": recoverable,
            "message": message,
        }));
    }
    // A Gen 3 barely declares bedtime periods, so an unanchored boot can hide every
    // night without producing a single undated one above. Say so from the clock
    // itself: whole days of history with no time anchor at all.
    if undated_nights.is_empty() {
        if let Some(epochs_arr) = clock_diag["epochs"].as_array() {
            let last_idx = epochs_arr.len().saturating_sub(1);
            let mut latest_unanchored_h = 0.0;
            let mut prior_unanchored_h = 0.0;
            for (idx, e) in epochs_arr.iter().enumerate() {
                if e["anchors"].as_u64() == Some(0) {
                    if let Some(h) = e["span_h"].as_f64().filter(|&h| h >= UNANCHORED_WARN_H) {
                        if idx == last_idx {
                            latest_unanchored_h += h;
                        } else {
                            prior_unanchored_h += h;
                        }
                    }
                }
            }
            let fmt_span = |h: f64| {
                if h >= 48.0 {
                    format!("{:.0} days", h / 24.0)
                } else {
                    format!("{h:.0} hours")
                }
            };
            if latest_unanchored_h > 0.0 {
                let msg = format!(
                    "About {} of current-boot ring history [missing_anchor] has no time anchor \
                     yet, so it cannot be placed on the calendar. Syncing while the ring remains \
                     in this boot epoch can anchor it.",
                    fmt_span(latest_unanchored_h)
                );
                clock_warnings.push(msg.clone());
                undated_reasons_json.push(json!({
                    "reason": ring_time::UndatedReason::MissingAnchor.code(),
                    "count": 0,
                    "span_h": (latest_unanchored_h * 10.0).round() / 10.0,
                    "recoverable": true,
                    "message": msg,
                }));
            }
            if prior_unanchored_h > 0.0 {
                let msg = format!(
                    "About {} of earlier-boot ring history [missing_anchor] was recorded before \
                     a reboot without a time anchor. Recovery is not possible from current \
                     evidence, and syncing again cannot retroactively anchor a prior boot.",
                    fmt_span(prior_unanchored_h)
                );
                clock_warnings.push(msg.clone());
                undated_reasons_json.push(json!({
                    "reason": ring_time::UndatedReason::MissingAnchor.code(),
                    "count": 0,
                    "span_h": (prior_unanchored_h * 10.0).round() / 10.0,
                    "recoverable": false,
                    "message": msg,
                }));
            }
        }
    }
    clock_diag["undated_reasons"] = json!(undated_reasons_json);
    clock_diag["warnings"] = json!(clock_warnings);

    Ok(json!({
        "generated_at": now,
        "tz": tz,
        "digest": digest,
        "clock": clock_diag,
        "device": device,
        "profile": demo.to_json(),
        "nights": nights_json,
        "sleep_debt": sleep_debt,
        // Model-free Symptom Radar: the same four biomarkers the torch illness model
        // eats, judged against the wearer's own baseline. Same JSON shape as
        // IllnessResult so one card renders either source.
        "symptoms": symptoms,
        "illness": illness,
        "cardio": cva,
        "fitness": { "vo2max": (vo2max * 10.0).round() / 10.0 },
        "activity": activity,
        "activity_profile": activity_profile,
        "activity_daily": activity_daily,
        "vitals": {
            "hrv": trend(&hrv_stat),
            "rhr": trend(&rhr_stat),
            "hr": latest_hr.map(|(at, bpm)| json!({
                "latest": bpm.round(),
                "date": date_label(at, tz),
                "hm": hm(at, tz),
                "at_unix": at.round() as i64,
            })),
        },
    }))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn fractional_timezone_preserves_minutes_and_day_boundaries() {
        assert_eq!(hm(0.0, 5.75), "05:45");
        assert_eq!(hm(0.0, -3.5), "20:30");
        assert_eq!(ymd_label(0.0, -3.5), "1969-12-31");
        assert_eq!(ymd_label(66600.0, 5.5), "1970-01-02");
    }

    #[test]
    fn battery_history_is_time_ordered_and_windowed() {
        let day = 86_400.0;
        // readings across three days, deliberately out of order
        let mut raw = vec![
            (3.0 * day, 70),
            (1.0 * day, 90),
            (2.0 * day, 80),
            (3.0 * day + 60.0, 71),
        ];
        raw.reverse();
        let got = battery_history(&raw, 2);
        // windowed to the last 2 days from the newest reading, oldest first
        assert_eq!(
            got,
            vec![
                [2.0 * day, 80.0],
                [3.0 * day, 70.0],
                [3.0 * day + 60.0, 71.0]
            ]
        );
        assert!(battery_history(&[], 14).is_empty());
    }

    #[test]
    fn timed_series_keeps_real_times_and_gaps() {
        let secs = |ds: i64| ds as f64 / 10.0;
        // 5-minute samples (3 000 ds) for the first half hour of an hour-long night, then
        // nothing: the points must stay in that first half, not be spread to the end.
        let samples: Vec<(i64, f64)> = (0..=6)
            .map(|i| (1_000 + i * 3_000, 60.0 + i as f64))
            .collect();
        let pts = timed_series(&samples, 1_000, 37_000, 240, 0, secs);
        assert_eq!(pts.len(), 7);
        assert_eq!(pts[0], [100.0, 60.0]);
        assert_eq!(pts[6], [1_900.0, 66.0], "the last sample stays at +30 min");
        // samples outside the night window are dropped
        assert!(timed_series(&[(0, 50.0), (40_000, 50.0)], 1_000, 37_000, 240, 0, secs).is_empty());
        // a dense stream is bucketed down to at most `max` points of bucket means
        let dense: Vec<(i64, f64)> = (0..1_000)
            .map(|i| (i * 10, if i % 2 == 0 { 10.0 } else { 20.0 }))
            .collect();
        let few = timed_series(&dense, 0, 10_000, 50, 1, secs);
        assert_eq!(few.len(), 50);
        assert!(few.iter().all(|p| (p[1] - 15.0).abs() < 1e-9), "{few:?}");
    }

    fn bed(start_ds: i64, end_ds: i64) -> BedPeriod {
        BedPeriod {
            start_ds,
            end_ds,
            raw_start_ds: start_ds,
            raw_end_ds: end_ds,
            captured_unix: 1,
            staged: false,
        }
    }

    #[test]
    fn identical_relative_starts_in_different_boots_keep_distinct_hypnograms() {
        let nights = [
            Night {
                start_ds: 0,
                end_ds: 36000,
                captured_unix: 1,
                ..Default::default()
            },
            Night {
                start_ds: 0,
                end_ds: 36000,
                captured_unix: 86401,
                ..Default::default()
            },
        ];
        let runs = [
            RingSleep {
                start_ds: 0,
                end_ds: 36000,
                captured_unix: 1,
                codes: vec![1; 120],
            },
            RingSleep {
                start_ds: 0,
                end_ds: 36000,
                captured_unix: 86401,
                codes: vec![3; 120],
            },
        ];
        let hyps: std::collections::HashMap<_, _> =
            ring_hypnograms(&runs, &nights, |ds, cu| ds as f64 / 10.0 + cu as f64)
                .into_iter()
                .collect();
        assert_eq!(hyps.len(), 2);
        assert_eq!(hyps[&(0, 1)]["stages"][0], 1);
        assert_eq!(hyps[&(0, 86401)]["stages"][0], 3);
    }

    #[test]
    fn missing_ring_stages_are_not_wake_or_sleep_latency() {
        let night = Night {
            start_ds: 0,
            end_ds: 8 * 36000,
            captured_unix: 1,
            ..Default::default()
        };
        let run = RingSleep {
            start_ds: 4 * 36000,
            end_ds: 8 * 36000,
            captured_unix: 1,
            codes: vec![2; 480],
        };
        let hyp = ring_hypnograms(&[run], &[night], |ds, _| ds as f64 / 10.0);
        let stages: Vec<i64> = hyp[0].1["stages"]
            .as_array()
            .unwrap()
            .iter()
            .map(|v| v.as_i64().unwrap())
            .collect();
        assert!(stages[..480].iter().all(|&c| c == 0));
        assert!(stages[480..].iter().all(|&c| c == 2));
        assert!(hyp[0].1["efficiency_pct"].is_null());
        let smoothed = smooth_stages(&stages, 5);
        assert!(smoothed[..480].iter().all(|&c| c == 0));
        let compact = downsample_codes(&smoothed, 120);
        assert!(compact[..60].iter().all(|&c| c == 0));
        assert_eq!(sleep_metrics(&smoothed, 8.0 * 3600.0), (Value::Null, 0));
    }

    #[test]
    fn measured_wake_is_preserved_and_complete_nights_still_score() {
        let night = Night {
            start_ds: 0,
            end_ds: 8 * 36000,
            captured_unix: 1,
            ..Default::default()
        };
        let mut codes = vec![4; 120];
        codes.extend(vec![2; 840]);
        let run = RingSleep {
            start_ds: 0,
            end_ds: 8 * 36000,
            captured_unix: 1,
            codes,
        };
        let hyp = ring_hypnograms(&[run], &[night], |ds, _| ds as f64 / 10.0);
        let stages: Vec<i64> = hyp[0].1["stages"]
            .as_array()
            .unwrap()
            .iter()
            .map(|v| v.as_i64().unwrap())
            .collect();
        let (metrics, asleep) = sleep_metrics(&stages, 8.0 * 3600.0);
        assert_eq!(metrics["sol_min"], 60.0);
        assert_eq!(asleep, 7 * 3600);
        assert_eq!(hyp[0].1["efficiency_pct"], 87.5);
    }

    #[test]
    fn ring_stages_do_not_leak_between_boots_with_overlapping_counters() {
        let night = Night {
            start_ds: 0,
            end_ds: 36000,
            captured_unix: 1,
            ..Default::default()
        };
        let run = RingSleep {
            start_ds: 0,
            end_ds: 36000,
            captured_unix: 86401,
            codes: vec![2; 120],
        };
        assert!(
            ring_hypnograms(&[run], &[night], |ds, cu| ds as f64 / 10.0 + cu as f64).is_empty()
        );
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
    fn sleep_need_defaults_until_enough_history_then_personalizes() {
        let mut sleep = std::collections::BTreeMap::new();
        for day in 100..113 {
            sleep.insert(day, 27000); // 7.5 h × 13 days — one short of the minimum
        }
        assert_eq!(sleep_need_s(&sleep, 113), 28800); // still the 8 h default
        sleep.insert(113, 27000); // 14th valid day
        assert_eq!(sleep_need_s(&sleep, 114), 27000); // typical sleep becomes the need
                                                      // causal: a day's own sleep is not part of its need window
        assert_eq!(sleep_need_s(&sleep, 113), 28800);
    }

    #[test]
    fn sleep_need_filters_outliers_and_clamps_to_healthy_band() {
        let mut sleep = std::collections::BTreeMap::new();
        for day in 100..120 {
            sleep.insert(day, 27000); // 7.5 h typical
        }
        sleep.insert(120, 2 * 3600); // an unusually short night
        sleep.insert(121, 13 * 3600); // and an unusually long one
        assert_eq!(sleep_need_s(&sleep, 122), 27000); // both filtered out

        let short: std::collections::BTreeMap<i64, i32> =
            (100..120).map(|d| (d, 5 * 3600)).collect(); // chronic 5 h sleeper
        assert_eq!(sleep_need_s(&short, 120), 7 * 3600); // clamped to the 7 h floor
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
        let got = normalize_bed_periods(periods, &[], &[], &[], |ds, _| ds as f64 / 10.0);
        assert_eq!(got, vec![bed(0, 7 * 3600 * 10)]);
    }

    #[test]
    fn nocturnal_signals_extend_a_premature_bedtime_end() {
        // the ring's marker ends early while its sleep streams keep coming (every 5 min)
        let bed_end = 5 * 3600 * 10;
        let support_end = 7 * 3600 * 10;
        let support: Vec<(i64, i64)> = (bed_end..=support_end)
            .step_by(5 * 60 * 10)
            .map(|ds| (ds, 1))
            .collect();
        let got = normalize_bed_periods(vec![bed(0, bed_end)], &support, &[], &[], |ds, _| {
            ds as f64 / 10.0
        });
        assert_eq!(got.len(), 1);
        assert_eq!(got[0].end_ds, support_end);
        assert_eq!(got[0].raw_end_ds, bed_end);
    }

    #[test]
    fn a_still_spell_hours_after_waking_does_not_extend_the_night() {
        let minute = 60 * 10;
        // Observed Ring 4, which reports no sleep_state: the ring's bedtime ends and its
        // sleep streams stop with it (every 5 min until then); 2.5 h later a 20-minute
        // burst of resting SpO2/temperature packets (sitting still) must not become part
        // of the night.
        let end = 8 * 60 * minute;
        let mut support: Vec<(i64, i64)> = (0..=end)
            .step_by(5 * minute as usize)
            .map(|ds| (ds, 1))
            .collect();
        support.extend((0..20).map(|i| (end + (150 + i) * minute, 1)));
        let got = normalize_bed_periods(vec![bed(0, end)], &support, &[], &[], |ds, _| {
            ds as f64 / 10.0
        });
        assert_eq!(got.len(), 1);
        assert_eq!(
            got[0].end_ds,
            end,
            "night ended {} min late",
            (got[0].end_ds - end) / minute
        );
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
        // the explicit sleep streams run on (every 5 min) from the marker to 05:34
        let support: Vec<(i64, i64)> = (raw_end..=explicit_end)
            .step_by(5 * minute as usize)
            .chain([explicit_end])
            .map(|ds| (ds, 1))
            .collect();
        let got = normalize_bed_periods(
            vec![bed(-6 * 3600 * 10, raw_end)],
            &support,
            &pulses,
            &[],
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
            &[],
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
            &[],
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
            &[],
            |ds, _| ds as f64 / 10.0,
        );
        assert_eq!(got[0].end_ds, 20 * minute);
    }

    #[test]
    fn pulse_cluster_after_long_gap_does_not_extend_sleep() {
        let minute = 60 * 10;
        let pulses = [(20 * minute, 1, 2), (20 * minute + 10 * 10, 1, 2)];
        let got =
            normalize_bed_periods(vec![bed(-6 * 3600 * 10, 0)], &[], &pulses, &[], |ds, _| {
                ds as f64 / 10.0
            });
        assert_eq!(got[0].end_ds, 0);
    }

    #[test]
    fn daytime_gap_remains_a_separate_sleep() {
        let periods = vec![bed(0, 30 * 60 * 10), bed(4 * 3600 * 10, 11 * 3600 * 10)];
        let got = normalize_bed_periods(periods.clone(), &[], &[], &[], |ds, _| ds as f64 / 10.0);
        assert_eq!(got, periods);
    }

    fn hex_bytes(s: &str) -> Vec<u8> {
        (0..s.len())
            .step_by(2)
            .map(|i| u8::from_str_radix(&s[i..i + 2], 16).unwrap())
            .collect()
    }

    #[test]
    fn raw_historical_ring_starts_withhold_ambiguous_stalled_nights_and_explain_why() {
        // Synthetic regression fixture reproducing the audited database's 7 raw
        // `ring_start` rows (decoded_json = NULL), 2 decoded `ring_start` rows, and the
        // stalled-anchor interval `47_893_458..61_076_535` (`1_787_733_221..1_789_195_418`)
        // containing both `49_912_254` (raw) and `57_660_709` (decoded).
        let dir = std::env::temp_dir().join(format!("oura-sum-reboot-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let db = dir.join("audit_reboots.db");
        let _ = std::fs::remove_file(&db);

        {
            let store = Store::open(&db).unwrap();
            drop(store);
        }
        let conn = rusqlite::Connection::open(&db).unwrap();
        // Reset decoder_version to 0 to simulate pre-migration database state.
        conn.execute("DELETE FROM store_meta", []).unwrap();

        let cap = 1_789_195_500_i64;
        // Anchor 1: ring_ds=47_893_458, unix_time=1_787_733_221
        conn.execute(
            "INSERT INTO events (serial, tag, name, ring_timestamp, body, decoded_json, captured_unix)
             VALUES ('S1', 66, 'time_sync', 47893458, X'A538106A', '{\"unix_time\":1787733221}', ?1)",
            rusqlite::params![1_787_733_300_i64],
        )
        .unwrap();

        // Raw historical reboot at 49_912_254 with decoded_json = NULL!
        let raw_reboot_49m = hex_bytes("0400000038020114010001020100");
        conn.execute(
            "INSERT INTO events (serial, tag, name, ring_timestamp, body, decoded_json, captured_unix)
             VALUES ('S1', 65, 'ring_start', 49912254, ?1, NULL, ?2)",
            rusqlite::params![raw_reboot_49m, cap],
        )
        .unwrap();

        // Already-decoded reboot at 57_660_709.
        conn.execute(
            "INSERT INTO events (serial, tag, name, ring_timestamp, body, decoded_json, captured_unix)
             VALUES ('S1', 65, 'ring_start', 57660709, ?1, '{\"reason\":4,\"firmware_version\":\"2.1.20\"}', ?2)",
            rusqlite::params![raw_reboot_49m, cap],
        )
        .unwrap();

        // Anchor 2: ring_ds=61_076_535, unix_time=1_789_195_418
        conn.execute(
            "INSERT INTO events (serial, tag, name, ring_timestamp, body, decoded_json, captured_unix)
             VALUES ('S1', 66, 'time_sync', 61076535, X'9A88266A', '{\"unix_time\":1789195418}', ?1)",
            rusqlite::params![cap],
        )
        .unwrap();

        // Three bedtime periods:
        // 1) Before first reboot (48_100_000..48_388_000) -> dated!
        // 2) Inside [49_912_254, 57_660_709] (52_000_000..52_288_000) -> withheld as ambiguous!
        // 3) After second reboot (58_500_000..58_788_000) -> dated!
        for (s, e) in [
            (48_100_000_i64, 48_388_000_i64),
            (52_000_000_i64, 52_288_000_i64),
            (58_500_000_i64, 58_788_000_i64),
        ] {
            let mut body = (s as u32).to_le_bytes().to_vec();
            body.extend_from_slice(&(e as u32).to_le_bytes());
            conn.execute(
                "INSERT INTO events (serial, tag, name, ring_timestamp, body, decoded_json, captured_unix)
                 VALUES ('S1', 118, 'bedtime_period', ?1, ?2, ?3, ?4)",
                rusqlite::params![
                    e,
                    body,
                    format!(
                        "{{\"bedtime_start_ds\":{s},\"bedtime_end_ds\":{e},\"duration_hours\":8.0}}"
                    ),
                    cap,
                ],
            )
            .unwrap();
        }
        drop(conn);

        let summary = build_summary(&db, 0.0, &NoModelRunner).unwrap();
        let dated = summary["nights"].as_array().unwrap();
        let undated = summary["clock"]["undated_nights"].as_array().unwrap();
        assert_eq!(dated.len(), 2, "only the pre-first-reboot and post-second-reboot windows are dated");
        assert_eq!(undated.len(), 1, "the window between the two reboots is withheld as ambiguous");
        assert_eq!(undated[0]["start_ds"], 52_000_000);
        assert_eq!(undated[0]["reason"], "ambiguous_reboot_stall");
        assert_eq!(undated[0]["recoverable"], false);

        let warnings = summary["clock"]["warnings"].as_array().unwrap();
        assert_eq!(warnings.len(), 1);
        let warn_text = warnings[0].as_str().unwrap();
        assert!(warn_text.contains("ambiguous_reboot_stall"), "{warn_text}");
        assert!(warn_text.contains("syncing again will not resolve"), "{warn_text}");

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn history_duration_and_event_totals_exclude_counter_jumps_and_distinguish_raw_counts() {
        let dir = std::env::temp_dir().join(format!("oura-sum-hist-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let db = dir.join("history_jump.db");
        let _ = std::fs::remove_file(&db);

        {
            let _ = Store::open(&db).unwrap();
        }
        let conn = rusqlite::Connection::open(&db).unwrap();
        let jul3 = 1_783_000_000_i64;
        let jul5 = jul3 + 2 * 86_400;

        // Initial erratic epoch: min_ds=20700, max_ds=184190173 (5115.8h raw counter jump)
        // while wall time only advances 1 hour on July 3, with a bedtime window inside the
        // erratic bracket.
        conn.execute(
            "INSERT INTO events (serial, tag, name, ring_timestamp, body, decoded_json, captured_unix)
             VALUES ('S1', 66, 'time_sync', 20700, X'00000000', ?1, ?2)",
            rusqlite::params![format!("{{\"unix_time\":{jul3}}}"), jul3],
        )
        .unwrap();
        conn.execute(
            "INSERT INTO events (serial, tag, name, ring_timestamp, body, decoded_json, captured_unix)
             VALUES ('S1', 118, 'bedtime_period', 90288000, X'0102030405060708',
                     '{\"bedtime_start_ds\":90000000,\"bedtime_end_ds\":90288000,\"duration_hours\":8.0}', ?1)",
            rusqlite::params![jul3 + 1800],
        )
        .unwrap();
        conn.execute(
            "INSERT INTO events (serial, tag, name, ring_timestamp, body, decoded_json, captured_unix)
             VALUES ('S1', 66, 'time_sync', 184190173, X'01000000', ?1, ?2)",
            rusqlite::params![format!("{{\"unix_time\":{}}}", jul3 + 3600), jul3 + 3600],
        )
        .unwrap();

        // Reboot to a clean boot spanning 2 days (July 3+1h to July 5) with 1 dated night
        // and 2 raw undecoded `raw_acm_event` (0x5f) rows.
        conn.execute(
            "INSERT INTO events (serial, tag, name, ring_timestamp, body, decoded_json, captured_unix)
             VALUES ('S1', 66, 'time_sync', 1000, X'02000000', ?1, ?2)",
            rusqlite::params![format!("{{\"unix_time\":{}}}", jul3 + 7200), jul3 + 7200],
        )
        .unwrap();
        conn.execute(
            "INSERT INTO events (serial, tag, name, ring_timestamp, body, decoded_json, captured_unix)
             VALUES ('S1', 118, 'bedtime_period', 300000, X'1112131415161718',
                     '{\"bedtime_start_ds\":12000,\"bedtime_end_ds\":300000,\"duration_hours\":8.0}', ?1)",
            rusqlite::params![jul5],
        )
        .unwrap();
        conn.execute(
            "INSERT INTO events (serial, tag, name, ring_timestamp, body, decoded_json, captured_unix)
             VALUES ('S1', 66, 'time_sync', 1657000, X'03000000', ?1, ?2)",
            rusqlite::params![format!("{{\"unix_time\":{jul5}}}"), jul5],
        )
        .unwrap();
        // Raw undecoded events (tag 0x5f = 95, decoded_json = NULL)
        for i in 0..2 {
            conn.execute(
                "INSERT INTO events (serial, tag, name, ring_timestamp, body, decoded_json, captured_unix)
                 VALUES ('S1', 95, 'raw_acm_event', ?1, ?2, NULL, ?3)",
                rusqlite::params![1657100 + i, vec![i as u8; 8], jul5],
            )
            .unwrap();
        }
        drop(conn);

        let summary = build_summary(&db, 0.0, &NoModelRunner).unwrap();
        // Elapsed wall time is jul3..jul5 = 2.0 days (NOT 213.2 + 2.0 = 215.2 days!).
        assert_eq!(summary["device"]["days_of_data"], 2.0);
        assert_eq!(summary["device"]["elapsed_days"], 2.0);
        assert_eq!(summary["device"]["observed_days"], 3);
        // 8 raw rows total, 6 decoded rows.
        assert_eq!(summary["device"]["total_events"], 8);
        assert_eq!(summary["device"]["raw_events"], 8);
        assert_eq!(summary["device"]["decoded_events"], 6);

        let undated = summary["clock"]["undated_nights"].as_array().unwrap();
        assert_eq!(undated.len(), 1);
        assert_eq!(undated[0]["reason"], "accelerated_counter");
        assert_eq!(undated[0]["recoverable"], false);

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn sleep_score_baselines_are_causal_exclude_naps_and_never_leak_future_nights() {
        struct FakeRunner;
        impl ModelRunner for FakeRunner {
            fn run(&self, input: ModelInputs) -> ModelOutputs {
                let arr: Vec<Value> = input
                    .sleep_ranges
                    .iter()
                    .map(|&[s, e, cu]| {
                        let epochs = ((e - s) / 300).max(1) as usize;
                        // All light sleep (code 2) for deterministic staging
                        json!({
                            "start_ds": s,
                            "end_ds": e,
                            "captured_unix": cu,
                            "stages": vec![2; epochs],
                            "deep_pct": 20.0,
                            "light_pct": 55.0,
                            "rem_pct": 25.0,
                            "wake_pct": 0.0,
                            "efficiency_pct": 95.0,
                            "source": "model",
                        })
                    })
                    .collect();
                ModelOutputs {
                    sleep_batch: Some(Value::Array(arr)),
                    ..Default::default()
                }
            }
        }

        let dir = std::env::temp_dir().join(format!("oura-sum-causal-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let db = dir.join("causal.db");
        let _ = std::fs::remove_file(&db);

        {
            let _ = Store::open(&db).unwrap();
        }
        let base_unix = 1_785_000_000_i64;
        let day_ds = 864_000_i64;
        let insert_session = |conn: &rusqlite::Connection,
                              idx: i64,
                              start_ds: i64,
                              dur_ds: i64,
                              hr: u8,
                              rmssd: u8| {
            let end_ds = start_ds + dur_ds;
            let cap = base_unix + (idx + 1) * 86_400;
            let mut bed_body = (start_ds as u32).to_le_bytes().to_vec();
            bed_body.extend_from_slice(&(end_ds as u32).to_le_bytes());
            conn.execute(
                "INSERT INTO events (serial, tag, name, ring_timestamp, body, decoded_json, captured_unix)
                 VALUES ('S1', 93, 'hrv_event', ?1, ?2, ?3, ?4)",
                rusqlite::params![
                    start_ds + 3000,
                    vec![hr, rmssd],
                    format!("{{\"hr_bpm\":[{hr}],\"rmssd_ms\":[{rmssd}],\"interval_min\":5}}"),
                    cap,
                ],
            )
            .unwrap();
            conn.execute(
                "INSERT INTO events (serial, tag, name, ring_timestamp, body, decoded_json, captured_unix)
                 VALUES ('S1', 118, 'bedtime_period', ?1, ?2, ?3, ?4)",
                rusqlite::params![
                    end_ds,
                    bed_body,
                    format!(
                        "{{\"bedtime_start_ds\":{start_ds},\"bedtime_end_ds\":{end_ds},\"duration_hours\":{}}}",
                        dur_ds as f64 / 36_000.0
                    ),
                    cap,
                ],
            )
            .unwrap();
        };

        let conn = rusqlite::Connection::open(&db).unwrap();
        conn.execute(
            "INSERT INTO events (serial, tag, name, ring_timestamp, body, decoded_json, captured_unix)
             VALUES ('S1', 66, 'time_sync', 1000, X'00000000', ?1, ?2)",
            rusqlite::params![format!("{{\"unix_time\":{base_unix}}}"), base_unix],
        )
        .unwrap();

        // Main nights 0, 1, 2 (8h each) + a 90-minute nap before night 2 + Main night 3 (8h).
        insert_session(&conn, 0, 10_000, 8 * 36_000, 50, 60);
        insert_session(&conn, 1, 10_000 + day_ds, 8 * 36_000, 52, 58);
        // Daytime nap (1.5h < 3h MIN_BASELINE_SLEEP_DS) with extreme HR=90, HRV=15: must be ignored by baseline!
        insert_session(&conn, 1, 10_000 + day_ds + 12 * 36_000, 90 * 600, 90, 15);
        insert_session(&conn, 2, 10_000 + 2 * day_ds, 8 * 36_000, 48, 62);
        insert_session(&conn, 3, 10_000 + 3 * day_ds, 8 * 36_000, 54, 50);
        drop(conn);

        let sum_before = build_summary(&db, 0.0, &FakeRunner).unwrap();
        // `nights` in summary JSON is newest-first:
        // index 0 = Night 3 (4th main night, has 3 prior main nights -> physiology component present!)
        // index 1 = Night 2 (3rd main night, has only 2 prior main nights because nap is excluded -> NO physiology component!)
        let nights_before = sum_before["nights"].as_array().unwrap();
        assert_eq!(nights_before.len(), 5);
        let night3_before = &nights_before[0]["sleep_score"];
        let night2_before = &nights_before[1]["sleep_score"];

        let has_physiology = |score: &Value| {
            score["components"]
                .as_array()
                .unwrap()
                .iter()
                .any(|c| c["key"] == "physiology")
        };
        assert!(
            has_physiology(night3_before),
            "4th main night has 3 prior main nights and must include physiology"
        );
        assert!(
            !has_physiology(night2_before),
            "3rd main night has only 2 prior main nights (nap excluded) and must omit physiology"
        );

        // Now append a future Night 4 with extreme RHR (99 bpm) and HRV (8 ms) and verify
        // earlier nights' sleep scores and physiology components are 100% unchanged.
        let conn = rusqlite::Connection::open(&db).unwrap();
        insert_session(&conn, 4, 10_000 + 4 * day_ds, 8 * 36_000, 99, 8);
        drop(conn);

        let sum_after = build_summary(&db, 0.0, &FakeRunner).unwrap();
        let nights_after = sum_after["nights"].as_array().unwrap();
        assert_eq!(nights_after.len(), 6);
        // nights_after[1..] correspond to nights_before[0..]
        for i in 0..nights_before.len() {
            assert_eq!(
                nights_after[i + 1]["sleep_score"],
                nights_before[i]["sleep_score"],
                "future night leaked into historical night at offset {i}"
            );
        }

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn refine_deep_stages_recovers_n3_bouts_from_zero_deep_gen4_hypnogram() {
        // Simulate an 8-hour night (960 x 30s epochs) where SleepNet produced only
        // Wake (4), REM (3), and Light (2) with 0% Deep (1) due to missing PPG amplitude.
        let start_ds = 10_000i64;
        let end_ds = start_ds + 960 * 300;
        let mut stages = vec![2i64; 960];
        for s in stages.iter_mut().take(30) {
            *s = 4;
        }
        for s in stages.iter_mut().skip(700).take(60) {
            *s = 3;
        }
        // Build 5-minute HR/HRV samples: quiet low-HR N3 bouts in the first half of the night
        let mut hr_t = Vec::new();
        let mut hrv_t = Vec::new();
        let mut motion_t = Vec::new();
        for i in 0..96 {
            let ds = start_ds + i * 3_000;
            let in_n3_bout = (8..22).contains(&i) || (30..40).contains(&i);
            let hr = if in_n3_bout { 51.0 } else { 58.0 };
            let hrv = if in_n3_bout { 46.0 } else { 36.0 };
            hr_t.push((ds, hr));
            hrv_t.push((ds, hrv));
        }
        for e in 0..960 {
            let ds = start_ds + e * 300;
            let m = if e < 30 { 8.0 } else { 0.0 };
            motion_t.push((ds, m));
        }

        let refined = refine_deep_stages(&stages, &hr_t, &motion_t, start_ds, end_ds);
        let deep_epochs = refined.iter().filter(|&&c| c == 1).count();
        let deep_pct = (deep_epochs as f64 / refined.len() as f64) * 100.0;
        assert!(
            (10.0..=28.0).contains(&deep_pct),
            "expected physiological N3 deep sleep recovery (10-28%), got {deep_pct:.1}% ({deep_epochs} epochs)"
        );
        // REM and Wake epochs must remain untouched.
        assert_eq!(refined[0], 4);
        assert_eq!(refined[720], 3);
    }

    #[test]
    fn stage_night_from_signals_produces_complete_four_stage_hypnogram() {
        let start_ds = 100_000i64;
        let end_ds = start_ds + 800 * 300;
        let mut hr_t = Vec::new();
        let mut hrv_t = Vec::new();
        let mut motion_t = Vec::new();
        for i in 0..80 {
            let ds = start_ds + i * 3_000;
            let hr = if i < 4 {
                68.0
            } else if (6..20).contains(&i) {
                50.0
            } else if (55..68).contains(&i) {
                61.0
            } else {
                56.0
            };
            let hrv = if (55..68).contains(&i) { 26.0 } else { 42.0 };
            hr_t.push((ds, hr));
            hrv_t.push((ds, hrv));
        }
        for e in 0..800 {
            let ds = start_ds + e * 300;
            let m = if e < 20 || e > 785 { 9.0 } else { 0.0 };
            motion_t.push((ds, m));
        }
        let stages = stage_night_from_signals(start_ds, end_ds, &hr_t, &hrv_t, &motion_t);
        assert_eq!(stages.len(), 800);
        assert!(stages.contains(&1));
        assert!(stages.contains(&2));
        assert!(stages.contains(&4));
    }

    #[test]
    fn manual_bedtime_override_updates_summary_bounds_and_resets_cleanly() {
        let dir = std::env::temp_dir().join(format!(
            "oura-bedtime-override-test-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        std::fs::create_dir_all(&dir).unwrap();
        let db = dir.join("oura.db");
        drop(Store::open(&db).unwrap());

        let base_unix = 1_780_000_000i64;
        let conn = rusqlite::Connection::open(&db).unwrap();
        conn.execute(
            "INSERT INTO events (serial, tag, name, ring_timestamp, body, decoded_json, captured_unix)
             VALUES ('S1', 66, 'time_sync', 1000, X'00000000', ?1, ?2)",
            rusqlite::params![format!("{{\"unix_time\":{base_unix}}}"), base_unix],
        )
        .unwrap();
        conn.execute(
            "INSERT INTO events (serial, tag, name, ring_timestamp, body, decoded_json, captured_unix)
             VALUES ('S1', 118, 'bedtime_period', 298000, X'00', '{\"bedtime_start_ds\":10000,\"bedtime_end_ds\":298000}', ?1)",
            rusqlite::params![base_unix + 30_000],
        )
        .unwrap();
        drop(conn);

        write_bedtime_override(
            &db,
            10_000,
            Some(base_unix + 30_000),
            Some(16_000),
            Some(292_000),
        )
        .unwrap();
        let sum = build_summary(&db, 0.0, &NoModelRunner).unwrap();
        let night = &sum["nights"].as_array().unwrap()[0];
        assert_eq!(night["start_ds"], 16_000);
        assert_eq!(night["end_ds"], 292_000);
        assert_eq!(night["raw_start_ds"], 10_000);
        assert_eq!(night["raw_end_ds"], 298_000);
        assert_eq!(night["bedtime_manual"], true);

        write_bedtime_override(&db, 10_000, Some(base_unix + 30_000), None, None).unwrap();
        let sum_reset = build_summary(&db, 0.0, &NoModelRunner).unwrap();
        let night_reset = &sum_reset["nights"].as_array().unwrap()[0];
        assert_eq!(night_reset["start_ds"], 10_000);
        assert_eq!(night_reset["end_ds"], 298_000);
        assert_eq!(night_reset["bedtime_manual"], false);

        let _ = std::fs::remove_dir_all(&dir);
    }
}

