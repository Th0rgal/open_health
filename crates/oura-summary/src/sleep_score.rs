//! A sleep score you can argue with.
//!
//! Oura's own 0–100 score is already reproduced elsewhere in this project, fitted from
//! a trends export (`oura-analysis`'s score fitting, R² 0.9986 on 684 days). This is
//! the other thing: a score built from *published* sleep science, where every threshold
//! is traceable to a paper rather than to a regression against a vendor's black box.
//! The two disagreeing is the interesting case, not a bug.
//!
//! ## Sources
//!
//! * **Ohayon M, et al. "National Sleep Foundation's sleep quality recommendations:
//!   first report." Sleep Health 2017;3(1):6–19.** Consensus appropriateness bands for
//!   sleep efficiency, latency, WASO and number of long awakenings, by age. Written to
//!   be applied exactly this way.
//! * **Hirshkowitz M, et al. "National Sleep Foundation's sleep time duration
//!   recommendations." Sleep Health 2015;1(1):40–43.** Duration by age band.
//! * **Boulos MI, et al. "Normal polysomnography parameters in healthy adults: a
//!   systematic review and meta-analysis." Lancet Respir Med 2019;7(6):533–543.**
//!   Stage percentages in healthy adults.
//! * **de Zambotti M, et al. "The sleep of the ring: comparison of the ŌURA sleep
//!   tracker against polysomnography." Behav Sleep Med 2019;17(2):124–136.** Why
//!   architecture is weighted low here: consumer PPG staging agrees with PSG far better
//!   on sleep/wake than on which stage, and deep sleep is the weakest of all.
//!
//! The thresholds below are transcribed from those papers' recommendation tables and
//! should be re-checked against the originals before anyone treats an individual number
//! as clinical. They are consensus *appropriateness* bands, not diagnostic cut-offs.
//!
//! ## Shape of the score
//!
//! Each component scores 0–100 through a piecewise-linear curve pinned at the papers'
//! band edges, then components combine as a weighted mean. A component with no data
//! drops out and the remaining weights renormalise, so a night without a hypnogram
//! still scores on duration, efficiency and physiology instead of being punished for
//! what the ring failed to record.
//!
//! Physiology (resting HR, HRV) is scored against **your own** baseline rather than a
//! population range, because the population spread of both dwarfs the night-to-night
//! change that actually means something.

use serde_json::{json, Value};

/// Minimum number of strictly preceding eligible main-sleep nights required before
/// scoring nocturnal physiology (RHR / HRV) against a personal baseline.
pub const MIN_BASELINE_NIGHTS: usize = 3;

/// Minimum sleep window duration (3 hours in deciseconds) for a session to count as
/// a main sleep rather than a nap when building personal physiology baselines.
pub const MIN_BASELINE_SLEEP_DS: i64 = 3 * 60 * 60 * 10;

/// Compute `(mean, sd)` from strictly preceding eligible nights in resolved
/// chronological order. Returns `None` when fewer than [`MIN_BASELINE_NIGHTS`]
/// finite observations are available, causing [`score_night`] to omit the
/// physiology component and renormalize the remaining weights.
pub fn causal_baseline(prior_values: &[f64]) -> Option<(f64, f64)> {
    if prior_values.len() < MIN_BASELINE_NIGHTS {
        return None;
    }
    let n = prior_values.len() as f64;
    let mean = prior_values.iter().sum::<f64>() / n;
    let variance = prior_values.iter().map(|v| (v - mean).powi(2)).sum::<f64>() / n;
    let sd = variance.sqrt();
    Some((mean, if sd > 1e-6 { sd } else { 1.0 }))
}

/// What a night needs to supply to be scored. Everything is optional: components with
/// no input drop out of the weighting rather than scoring zero.
#[derive(Default, Clone, Copy)]
pub struct NightInput {
    pub asleep_min: Option<f64>,
    pub efficiency_pct: Option<f64>,
    pub onset_latency_min: Option<f64>,
    pub waso_min: Option<f64>,
    pub awakenings: Option<f64>,
    pub deep_pct: Option<f64>,
    pub rem_pct: Option<f64>,
    /// Lowest resting HR of the night, with the wearer's own baseline mean/SD.
    pub rhr: Option<f64>,
    pub rhr_baseline: Option<(f64, f64)>,
    pub hrv_ms: Option<f64>,
    pub hrv_baseline: Option<(f64, f64)>,
    /// Age in years — the recommendation bands are age-specific.
    pub age: f64,
}

struct Component {
    key: &'static str,
    score: f64,
    weight: f64,
    detail: Value,
}

/// Piecewise-linear interpolation through `(input, score)` anchors, which must be
/// sorted by input. Outside the ends it clamps, so an absurd input cannot produce an
/// absurd score.
fn curve(x: f64, anchors: &[(f64, f64)]) -> f64 {
    if x <= anchors[0].0 {
        return anchors[0].1;
    }
    for pair in anchors.windows(2) {
        let ((x0, y0), (x1, y1)) = (pair[0], pair[1]);
        if x <= x1 {
            let t = if (x1 - x0).abs() < f64::EPSILON {
                0.0
            } else {
                (x - x0) / (x1 - x0)
            };
            return y0 + t * (y1 - y0);
        }
    }
    anchors[anchors.len() - 1].1
}

/// Recommended sleep duration in hours for an age (Hirshkowitz 2015, Table 1):
/// `(may be appropriate low, recommended low, recommended high, may be appropriate
/// high)`.
fn duration_band(age: f64) -> (f64, f64, f64, f64) {
    match age {
        a if a < 14.0 => (7.0, 9.0, 11.0, 12.0),  // school age
        a if a < 18.0 => (7.0, 8.0, 10.0, 11.0),  // teen
        a if a < 26.0 => (6.0, 7.0, 9.0, 11.0),   // young adult
        a if a < 65.0 => (6.0, 7.0, 9.0, 10.0),   // adult
        _ => (5.0, 7.0, 8.0, 9.0),                // older adult
    }
}

/// Score one night. Returns `null` when nothing scoreable was supplied.
pub fn score_night(input: NightInput) -> Value {
    let mut components: Vec<Component> = Vec::new();

    // ── duration (Hirshkowitz 2015) ─────────────────────────────────────────────
    // Weighted highest: it is the best-measured thing a ring reports and the one with
    // the strongest outcome literature behind it.
    if let Some(asleep_min) = input.asleep_min {
        let hours = asleep_min / 60.0;
        let (may_lo, rec_lo, rec_hi, may_hi) = duration_band(input.age);
        let score = curve(
            hours,
            &[
                (may_lo - 2.0, 0.0),
                (may_lo, 50.0),
                (rec_lo, 90.0),
                (rec_lo + 0.5, 100.0),
                (rec_hi, 100.0),
                (may_hi, 75.0),
                (may_hi + 2.0, 40.0),
            ],
        );
        components.push(Component {
            key: "duration",
            score,
            weight: 0.30,
            detail: json!({
                "value_h": (hours * 10.0).round() / 10.0,
                "recommended_h": [rec_lo, rec_hi],
                "source": "Hirshkowitz 2015 (NSF duration)",
            }),
        });
    }

    // ── efficiency (Ohayon 2017) ────────────────────────────────────────────────
    // >=85% appropriate for every adult band; <75% inappropriate.
    if let Some(efficiency) = input.efficiency_pct {
        components.push(Component {
            key: "efficiency",
            score: curve(
                efficiency,
                &[(60.0, 0.0), (75.0, 40.0), (85.0, 85.0), (92.0, 100.0), (100.0, 100.0)],
            ),
            weight: 0.20,
            detail: json!({
                "value_pct": efficiency.round(),
                "appropriate_at_or_above": 85,
                "source": "Ohayon 2017 (NSF quality)",
            }),
        });
    }

    // ── sleep onset latency (Ohayon 2017) ───────────────────────────────────────
    // <=15 min appropriate for adults, 16-30 uncertain, >60 inappropriate.
    if let Some(latency) = input.onset_latency_min {
        components.push(Component {
            key: "onset_latency",
            score: curve(
                latency,
                &[(0.0, 100.0), (15.0, 100.0), (30.0, 70.0), (45.0, 40.0), (60.0, 20.0), (120.0, 0.0)],
            ),
            weight: 0.10,
            detail: json!({
                "value_min": latency.round(),
                "appropriate_at_or_below": 15,
                "source": "Ohayon 2017 (NSF quality)",
            }),
        });
    }

    // ── wake after sleep onset (Ohayon 2017) ────────────────────────────────────
    // <=20 min appropriate for 18-64; the older band tolerates more.
    if let Some(waso) = input.waso_min {
        let appropriate = if input.age >= 65.0 { 30.0 } else { 20.0 };
        components.push(Component {
            key: "waso",
            score: curve(
                waso,
                &[
                    (0.0, 100.0),
                    (appropriate, 95.0),
                    (appropriate * 2.0, 65.0),
                    (appropriate * 3.0, 35.0),
                    (appropriate * 5.0, 0.0),
                ],
            ),
            weight: 0.15,
            detail: json!({
                "value_min": waso.round(),
                "appropriate_at_or_below": appropriate,
                "source": "Ohayon 2017 (NSF quality)",
            }),
        });
    }

    // ── awakenings (Ohayon 2017) ────────────────────────────────────────────────
    // The paper counts awakenings LONGER THAN 5 MINUTES (<=1 appropriate for 18-64).
    // A hypnogram-derived count includes brief arousals the paper would not have
    // counted, so this is scored leniently and weighted low — an honest mismatch, not
    // a hidden one.
    if let Some(awakenings) = input.awakenings {
        components.push(Component {
            key: "awakenings",
            score: curve(awakenings, &[(0.0, 100.0), (2.0, 95.0), (5.0, 75.0), (10.0, 45.0), (20.0, 10.0)]),
            weight: 0.05,
            detail: json!({
                "value": awakenings,
                "note": "hypnogram arousals; Ohayon counts only awakenings >5 min",
                "source": "Ohayon 2017 (NSF quality)",
            }),
        });
    }

    // ── architecture (Boulos 2019) ──────────────────────────────────────────────
    // Deliberately the smallest weight in the score. Consumer PPG staging is far
    // weaker at WHICH stage than at asleep-vs-awake (de Zambotti 2019), and deep sleep
    // is where it is weakest — scoring it heavily would mostly score the ring's error.
    let mut architecture: Vec<f64> = Vec::new();
    let mut architecture_detail = json!({});
    if let Some(deep) = input.deep_pct {
        architecture.push(curve(
            deep,
            &[(0.0, 0.0), (8.0, 50.0), (13.0, 95.0), (16.0, 100.0), (23.0, 100.0), (35.0, 85.0)],
        ));
        architecture_detail["deep_pct"] = json!(deep.round());
        architecture_detail["healthy_deep_pct"] = json!([13, 23]);
    }
    if let Some(rem) = input.rem_pct {
        architecture.push(curve(
            rem,
            &[(0.0, 0.0), (10.0, 45.0), (20.0, 95.0), (22.0, 100.0), (25.0, 100.0), (35.0, 80.0)],
        ));
        architecture_detail["rem_pct"] = json!(rem.round());
        architecture_detail["healthy_rem_pct"] = json!([20, 25]);
    }
    if !architecture.is_empty() {
        architecture_detail["source"] = json!("Boulos 2019 (PSG meta-analysis)");
        architecture_detail["note"] =
            json!("weighted low: consumer staging is weakest at deep sleep");
        components.push(Component {
            key: "architecture",
            score: architecture.iter().sum::<f64>() / architecture.len() as f64,
            weight: 0.10,
            detail: architecture_detail,
        });
    }

    // ── restorative physiology, against the wearer's own baseline ───────────────
    let mut physiology: Vec<f64> = Vec::new();
    let mut physiology_detail = json!({});
    if let (Some(rhr), Some((mean, sd))) = (input.rhr, input.rhr_baseline) {
        if sd > 0.0 {
            let z = (rhr - mean) / sd;
            // Below your own baseline is good; elevated resting HR is the classic
            // "something is off" signal (strain, alcohol, illness coming on).
            physiology.push(curve(z, &[(-2.0, 100.0), (0.0, 90.0), (1.0, 70.0), (2.0, 40.0), (3.5, 10.0)]));
            physiology_detail["rhr"] = json!(rhr.round());
            physiology_detail["rhr_z"] = json!((z * 10.0).round() / 10.0);
        }
    }
    if let (Some(hrv), Some((mean, sd))) = (input.hrv_ms, input.hrv_baseline) {
        if sd > 0.0 {
            let z = (hrv - mean) / sd;
            physiology.push(curve(z, &[(-3.0, 10.0), (-2.0, 35.0), (-1.0, 70.0), (0.0, 90.0), (1.5, 100.0)]));
            physiology_detail["hrv_ms"] = json!(hrv.round());
            physiology_detail["hrv_z"] = json!((z * 10.0).round() / 10.0);
        }
    }
    if !physiology.is_empty() {
        physiology_detail["note"] = json!("scored against your own baseline, not a population range");
        components.push(Component {
            key: "physiology",
            score: physiology.iter().sum::<f64>() / physiology.len() as f64,
            weight: 0.10,
            detail: physiology_detail,
        });
    }

    if components.is_empty() {
        return Value::Null;
    }
    let total_weight: f64 = components.iter().map(|c| c.weight).sum();
    let score: f64 = components.iter().map(|c| c.score * c.weight).sum::<f64>() / total_weight;

    json!({
        "score": score.round(),
        "components": components
            .iter()
            .map(|c| {
                json!({
                    "key": c.key,
                    "score": c.score.round(),
                    // the weight actually applied, after renormalising for whatever
                    // this night was missing
                    "weight": ((c.weight / total_weight) * 100.0).round() / 100.0,
                    "detail": c.detail,
                })
            })
            .collect::<Vec<_>>(),
        "basis": "published norms (NSF 2015/2017, Boulos 2019)",
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn adult(mut input: NightInput) -> NightInput {
        input.age = 40.0;
        input
    }

    #[test]
    fn curve_clamps_outside_its_anchors() {
        let anchors = [(0.0, 10.0), (10.0, 90.0)];
        assert_eq!(curve(-5.0, &anchors), 10.0);
        assert_eq!(curve(50.0, &anchors), 90.0);
        assert_eq!(curve(5.0, &anchors), 50.0);
    }

    #[test]
    fn a_textbook_night_scores_high() {
        let v = score_night(adult(NightInput {
            asleep_min: Some(8.0 * 60.0),
            efficiency_pct: Some(92.0),
            onset_latency_min: Some(12.0),
            waso_min: Some(15.0),
            awakenings: Some(1.0),
            deep_pct: Some(18.0),
            rem_pct: Some(22.0),
            ..Default::default()
        }));
        assert!(v["score"].as_f64().unwrap() >= 95.0, "{v}");
    }

    #[test]
    fn short_broken_sleep_scores_low() {
        let v = score_night(adult(NightInput {
            asleep_min: Some(4.0 * 60.0),
            efficiency_pct: Some(66.0),
            onset_latency_min: Some(55.0),
            waso_min: Some(90.0),
            awakenings: Some(12.0),
            deep_pct: Some(5.0),
            rem_pct: Some(8.0),
            ..Default::default()
        }));
        assert!(v["score"].as_f64().unwrap() <= 40.0, "{v}");
    }

    /// The whole point of renormalising: a model-free night has no hypnogram, so it
    /// must still score on what it does have rather than being marked down for it.
    #[test]
    fn missing_components_renormalise_instead_of_scoring_zero() {
        let full = score_night(adult(NightInput {
            asleep_min: Some(8.0 * 60.0),
            efficiency_pct: Some(90.0),
            deep_pct: Some(18.0),
            rem_pct: Some(22.0),
            ..Default::default()
        }));
        let partial = score_night(adult(NightInput {
            asleep_min: Some(8.0 * 60.0),
            efficiency_pct: Some(90.0),
            ..Default::default()
        }));
        let (a, b) = (full["score"].as_f64().unwrap(), partial["score"].as_f64().unwrap());
        assert!((a - b).abs() < 6.0, "full {a} vs partial {b}");
        let weights: f64 = partial["components"]
            .as_array()
            .unwrap()
            .iter()
            .map(|c| c["weight"].as_f64().unwrap())
            .sum();
        assert!((weights - 1.0).abs() < 0.02, "weights must renormalise: {weights}");
    }

    #[test]
    fn duration_bands_follow_age() {
        let night = |hours: f64, age: f64| {
            score_night(NightInput {
                asleep_min: Some(hours * 60.0),
                age,
                ..Default::default()
            })["score"]
                .as_f64()
                .unwrap()
        };
        // 7.5 h is inside the recommended band for both (7-9 adult, 7-8 older adult)
        assert_eq!(night(7.5, 40.0), 100.0);
        assert_eq!(night(7.5, 70.0), 100.0);
        // 9.5 h is still "may be appropriate" at 40 but past the older-adult band
        assert!(
            night(9.5, 40.0) > night(9.5, 70.0),
            "{} vs {}",
            night(9.5, 40.0),
            night(9.5, 70.0)
        );
        // and a teenager needs more than an adult for the same 6.5 h
        assert!(night(6.5, 16.0) < night(6.5, 40.0));
    }

    #[test]
    fn physiology_uses_the_wearers_own_baseline() {
        let base = NightInput {
            asleep_min: Some(8.0 * 60.0),
            rhr: Some(48.0),
            hrv_ms: Some(60.0),
            ..Default::default()
        };
        let calm = score_night(adult(NightInput {
            rhr_baseline: Some((50.0, 3.0)),
            hrv_baseline: Some((55.0, 8.0)),
            ..base
        }));
        let strained = score_night(adult(NightInput {
            rhr_baseline: Some((42.0, 3.0)),
            hrv_baseline: Some((80.0, 8.0)),
            ..base
        }));
        // identical night, different person: 48 bpm is low for one and elevated for the other
        assert!(
            calm["score"].as_f64().unwrap() > strained["score"].as_f64().unwrap(),
            "{calm} vs {strained}"
        );
    }
}
