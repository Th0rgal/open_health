//! Daily sleep, readiness and activity scores on a 0-100 scale, keyed by wake date.
//!
//! These are estimates, not Oura's scores. Sleep is the night's `sleep_score`. Readiness
//! is the weighted mean of the contributors this crate can compute, with the weights
//! recovered for Oura's readiness score (`docs/algorithms/score-weights.md`) and
//! renormalized over the available ones. Activity is the mean of a steps score and an
//! active-calorie score against fixed targets.

use serde_json::{json, Value};

const BASELINE_NIGHTS: usize = 14;
const MIN_BASELINE_NIGHTS: usize = 3;
/// Shorter sleeps are naps and do not set the day's score or baselines.
const MIN_MAIN_SLEEP_H: f64 = 3.0;
const STEP_TARGET: f64 = 10_000.0;
const ACTIVE_KCAL_TARGET: f64 = 400.0;

/// Piecewise-linear interpolation through `(x, score)` knots, flat outside them.
fn interp(x: f64, knots: &[(f64, f64)]) -> f64 {
    let (first, last) = (knots[0], knots[knots.len() - 1]);
    if x <= first.0 {
        return first.1;
    }
    for w in knots.windows(2) {
        if x <= w[1].0 {
            return w[0].1 + (w[1].1 - w[0].1) * (x - w[0].0) / (w[1].0 - w[0].0);
        }
    }
    last.1
}

fn mean(v: &[f64]) -> f64 {
    v.iter().sum::<f64>() / v.len() as f64
}

/// Mean of the last `BASELINE_NIGHTS` prior values, when there are enough of them.
fn baseline(prior: &[f64]) -> Option<f64> {
    let recent = &prior[prior.len().saturating_sub(BASELINE_NIGHTS)..];
    (recent.len() >= MIN_BASELINE_NIGHTS).then(|| mean(recent))
}

fn weighted(parts: &[(f64, f64)]) -> Option<f64> {
    let weight: f64 = parts.iter().map(|p| p.0).sum();
    (weight > 0.0).then(|| parts.iter().map(|p| p.0 * p.1).sum::<f64>() / weight)
}

fn debt_score(state: &str) -> Option<f64> {
    match state {
        "none" => Some(100.0),
        "low" => Some(85.0),
        "moderate" => Some(65.0),
        "high" => Some(40.0),
        _ => None,
    }
}

fn activity_score(day: &Value) -> Option<f64> {
    if let Some(score) = day["score"].as_f64() {
        return Some(score);
    }
    let steps = day["steps"].as_f64()?;
    let kcal = day["active_kcal"].as_f64()?;
    let part = |x: f64, target: f64| (x / target).min(1.0) * 100.0;
    Some((part(steps, STEP_TARGET) + part(kcal, ACTIVE_KCAL_TARGET)) / 2.0)
}

/// `{ "<wake date>": { "sleep", "readiness", "activity" } }`, each score null when its
/// inputs are missing. `nights` is the summary's `nights` array in any order.
pub fn daily_scores(nights: &[Value], activity_daily: &Value, sleep_debt: &Value) -> Value {
    let mut main: Vec<&Value> = nights
        .iter()
        .filter(|n| n["in_bed_h"].as_f64().unwrap_or(0.0) >= MIN_MAIN_SLEEP_H)
        .collect();
    main.sort_by_key(|n| n["end_unix"].as_i64().unwrap_or(0));
    let (mut hrv, mut rhr, mut temp) = (vec![], vec![], vec![]);
    let mut out = serde_json::Map::new();
    for n in main {
        let Some(day) = n["wake_ymd"].as_str() else { continue };
        let sleep = n["oura_sleep_score"]["score"].as_f64().or_else(|| n["sleep_score"]["score"].as_f64());
        let debt = sleep_debt["days"]
            .as_array()
            .and_then(|d| d.iter().find(|e| e["date"] == day))
            .and_then(|e| debt_score(e["state"].as_str()?));
        let contributor = |value: Option<f64>, prior: &[f64], weight: f64, f: fn(f64) -> f64| {
            let (v, b) = (value?, baseline(prior)?);
            Some((weight, f(v / b)))
        };
        let parts: Vec<(f64, f64)> = [
            sleep.map(|s| (15.0, s)),
            debt.map(|d| (12.0, d)),
            contributor(n["hrv_ms"].as_f64(), &hrv, 15.0, |r| {
                interp(r, &[(0.7, 30.0), (0.9, 70.0), (1.0, 90.0), (1.1, 100.0)])
            }),
            contributor(n["rhr"].as_f64(), &rhr, 17.0, |r| {
                interp(r, &[(1.0, 100.0), (1.05, 85.0), (1.1, 60.0), (1.2, 30.0)])
            }),
            // temperature is a deviation in degrees, so compare by difference
            n["skin_temp"].as_f64().zip(baseline(&temp)).map(|(t, b)| {
                (13.0, interp((t - b).abs(), &[(0.3, 100.0), (0.6, 80.0), (1.0, 50.0), (1.5, 20.0)]))
            }),
        ]
        .into_iter()
        .flatten()
        .collect();
        // a readiness needs last night plus at least one physiological contributor
        let readiness = n["oura_readiness"]["score"].as_f64().or_else(|| {
            if sleep.is_some() && parts.len() >= 3 { weighted(&parts) } else { None }
        });
        out.insert(
            day.to_string(),
            json!({
                "sleep": sleep.map(f64::round),
                "readiness": readiness.map(f64::round),
                "activity": activity_score(&activity_daily[day]).map(f64::round),
            }),
        );
        for (series, value) in [(&mut hrv, "hrv_ms"), (&mut rhr, "rhr"), (&mut temp, "skin_temp")] {
            if let Some(v) = n[value].as_f64() {
                series.push(v);
            }
        }
    }
    Value::Object(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn night(day: &str, end: i64, hrv: f64, rhr: f64, temp: f64, sleep: f64) -> Value {
        json!({ "wake_ymd": day, "end_unix": end, "in_bed_h": 8.0, "hrv_ms": hrv, "rhr": rhr,
                "skin_temp": temp, "sleep_score": { "score": sleep } })
    }

    #[test]
    fn interp_is_flat_outside_the_knots_and_linear_between() {
        let k = [(1.0, 100.0), (1.1, 60.0)];
        assert_eq!(interp(0.5, &k), 100.0);
        assert_eq!(interp(1.05, &k), 80.0);
        assert_eq!(interp(2.0, &k), 60.0);
    }

    #[test]
    fn readiness_waits_for_a_baseline_and_rewards_a_baseline_night() {
        let nights: Vec<Value> = (1..=5)
            .map(|d| night(&format!("2025-01-0{d}"), d * 100_000, 80.0, 50.0, 34.0, 90.0))
            .collect();
        let debt = json!({ "days": [{ "date": "2025-01-05", "state": "none" }] });
        let s = daily_scores(&nights, &json!({}), &debt);
        assert!(s["2025-01-01"]["readiness"].is_null());
        assert_eq!(s["2025-01-05"]["readiness"], 96.0);
        assert_eq!(s["2025-01-05"]["sleep"], 90.0);
    }

    #[test]
    fn activity_saturates_at_the_targets() {
        let day = json!({ "steps": 5000.0, "active_kcal": 800.0 });
        assert_eq!(activity_score(&day), Some(75.0));
    }
}
