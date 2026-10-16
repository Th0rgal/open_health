//! Daily sleep score and readiness from the ported daily scorer
//! (`oura_analysis::ported::daily::DailyScorer`).
//!
//! Each wake date groups the sleep periods that ended on it. The scorer carries what it
//! keeps between days (the nine personal baselines, seeded from `COLD_START_MEANS` or
//! `profile.json`, and 14 days of history), so the days are replayed oldest first.
//!
//! The sleep-regularity input is a fixed constant, the temperature deviation
//! histories are empty, and rest mode is left off because the rest-mode ring events are not
//! stored.

use crate::activity_day::DayResult;
use oura_analysis::ported::daily::{DailyScorer, DEFAULT_DEVS, SRI};
use oura_analysis::ported::readiness_inputs::{DailySleep, SleepPeriod};
use serde_json::{json, Value};
use std::collections::BTreeMap;

/// Main sleeps shorter than this are naps.
const MIN_MAIN_SLEEP_H: f64 = 3.0;

/// The date before `ymd`, as the activity-day key.
fn previous_day(ymd: &str) -> Option<String> {
    let mut p = ymd.split('-');
    let (y, m, d): (i64, u32, u32) = (p.next()?.parse().ok()?, p.next()?.parse().ok()?, p.next()?.parse().ok()?);
    let (y, m, d) = crate::civil(crate::days_from_civil(y, m, d) - 1);
    Some(format!("{y:04}-{m:02}-{d:02}"))
}

fn u(v: &Value, k: &str) -> u32 {
    v[k].as_f64().unwrap_or(0.0).max(0.0) as u32
}

fn period_of(n: &Value, is_main: bool) -> Option<SleepPeriod> {
    let p = &n["oura_sleep_score"]["period"];
    if p.is_null() {
        return None;
    }
    let start = p["start"].as_i64()?;
    // lowest heart rate, RMSSD and highest temperature as the night summary computes them
    // (open_oura `ported::night_summary`, run when the night is built)
    let sum = &n["night_summary"];
    let lowest_hr = u(sum, "lowest_hr");
    Some(SleepPeriod {
        is_main: is_main as u32,
        start,
        tz: p["tz"].as_i64().unwrap_or(0) as i32,
        time_in_bed: u(p, "time_in_bed"),
        total_sleep: u(p, "total_sleep"),
        rem: u(p, "rem"),
        deep: u(p, "deep"),
        efficiency: u(p, "efficiency"),
        latency: u(p, "latency"),
        wake_ups: u(p, "wake_ups"),
        restless: u(p, "restless"),
        got_up: u(p, "got_up"),
        midpoint: u(p, "midpoint"),
        highest_temp: u(sum, "highest_temp"),
        lowest_hr: if lowest_hr == 0 { u32::MAX } else { lowest_hr },
        lowest_hr_time: u(sum, "lowest_hr_time"),
        rmssd: u(sum, "rmssd"),
    })
}

fn sleep_json(d: &DailySleep, score: u32) -> Value {
    let c = d.contributors;
    json!({
        "score": score,
        "contributors": {
            "total": c[0], "deep": c[1], "rem": c[2], "efficiency": c[3],
            "latency": c[4], "restfulness": c[5], "timing": c[6],
        },
    })
}

/// Sets `oura_sleep_score` and `oura_readiness` on the night that is each wake date's main
/// sleep. `activity` is keyed by activity-day date; `chronotype` is `(type, ideal midpoint s)`,
/// and without one the default timing reference applies (type 0).
/// Day-0 baseline means used when `profile.json` has no `baseline_seed`: sleep score 75, sleep time
/// 420 min, resting HR 50 bpm, 300 min from the lowest HR to waking, distance 1000, vigorous 5,
/// sedentary 480 min, skin temperature 36.5 C, HRV 55 ms (8x scaled; temperature x800, HRV x80).
/// The deviations are the library's.
pub const COLD_START_MEANS: [u16; 9] = [600, 3360, 400, 2400, 8000, 40, 3840, 29200, 4400];

pub fn annotate(
    nights: &mut [Value],
    activity: &BTreeMap<String, DayResult>,
    age: u32,
    chronotype: Option<(u8, i32)>,
    baseline_seed: Option<([u16; 9], [u16; 9])>,
) {
    let mut by_day: BTreeMap<String, Vec<usize>> = BTreeMap::new();
    for (i, n) in nights.iter().enumerate() {
        if let (Some(day), false) = (n["wake_ymd"].as_str(), n["oura_sleep_score"]["period"].is_null()) {
            by_day.entry(day.to_string()).or_default().push(i);
        }
    }
    // the profile's day-0 baselines when it has them, else a generic adult prior
    let mut scorer = match baseline_seed {
        Some((means, devs)) => DailyScorer::with_baseline(&means, &devs),
        None => DailyScorer::with_baseline(&COLD_START_MEANS, &DEFAULT_DEVS),
    }
    .track_sri();
    for (ymd, idx) in by_day {
        // the longest sleep of at least MIN_MAIN_SLEEP_H is the main one
        let hours = |i: usize| nights[i]["in_bed_h"].as_f64().unwrap_or(0.0);
        let Some(main) = idx.iter().copied().filter(|&i| hours(i) >= MIN_MAIN_SLEEP_H)
            .max_by(|&a, &b| hours(a).total_cmp(&hours(b))) else { continue };
        let mut order = idx.clone();
        order.sort_by_key(|&i| nights[i]["oura_sleep_score"]["period"]["start"].as_i64().unwrap_or(0));
        // a nap with no asleep epoch (a short window the ring declared) carries no sleep; the day
        // is scored on its other periods, and only an unstaged main sleep leaves it unscored
        let periods: Vec<SleepPeriod> = order
            .iter()
            .filter_map(|&i| period_of(&nights[i], i == main))
            .filter(|p| p.total_sleep > 0 || p.is_main == 1)
            .collect();
        if periods.is_empty() || periods.iter().any(|p| p.total_sleep == 0) {
            continue;
        }
        let end = nights[main]["end_unix"].as_i64().unwrap_or(0);
        // [_, distance, non-wear, sedentary, vigorous, light, moderate, resting] of the activity day before
        let prev = previous_day(&ymd).and_then(|k| activity.get(&k)).map_or([0u32; 8], |d| {
            let s = &d.stats;
            [0, s.eq_distance, s.non_wear, s.classes[1], s.classes[4], s.classes[2], s.classes[3], s.classes[0]]
        });
        let res = scorer.step(end / 86400 * 86400, age, &periods, &prev, Some(chronotype.unwrap_or((0, 0))), SRI);
        let (sleep, score) = match &res.outputs {
            Some(o) => (o.sleep, o.sleep.score),
            None => (res.sleep, res.sleep.score),
        };
        nights[main]["oura_sleep_score"] = sleep_json(&sleep, score);
        nights[main]["oura_readiness"] = match (res.readiness_score, res.contributors) {
            (Some(score), Some(c)) => json!({
                "score": score,
                "contributors": {
                    "activity_balance": c[0], "last_day_activity": c[1], "last_night": c[2],
                    "resting_hr": c[3], "recovery_index": c[4], "sleep_balance": c[5],
                    "temperature": c[6], "hrv_balance": c[7], "sleep_regularity": c[8],
                },
            }),
            _ => Value::Null,
        };
    }
}
