//! Per-day activity statistics and score from the ring's per-minute MET bytes. The day
//! bookkeeping is the stateless day path in
//! `oura_analysis::ported::activity_day::compute_stateless`; this module reads the events it
//! needs from the store's decoded events and renders a day as the summary JSON.

use oura_analysis::ported::actinfo::User;
use oura_analysis::ported::activity_day::{
    compute_stateless, met_byte, AlertEvent, Anchor, RingEvent, StatelessInputs, WearEvent,
};
pub use oura_analysis::ported::activity_day::DayResult;
use serde_json::{json, Value};
use std::collections::BTreeMap;

const TAG_TIME_SYNC: u8 = 0x42;
const TAG_ACTIVITY: u8 = 0x50;
const TAG_WEAR: u8 = 0x53;
const TAG_ALERT: u8 = 0x56;

/// Days of activity from the decoded events `(ring ds, tag, json, captured_unix)`. `sleeps` are
/// the night windows as Unix seconds, `readiness` the readiness score by date (80 when absent).
pub fn compute(
    events: &[(i64, u8, String, i64)],
    sleeps: &[(f64, f64)],
    user: User,
    tz: f64,
    readiness: &BTreeMap<String, u32>,
) -> BTreeMap<String, DayResult> {
    let (mut anchors, mut acts, mut wear, mut alerts) = (Vec::new(), Vec::new(), Vec::new(), Vec::new());
    for (ds, tag, json, _) in events {
        if !matches!(*tag, TAG_TIME_SYNC | TAG_ACTIVITY | TAG_WEAR | TAG_ALERT) {
            continue;
        }
        let Ok(v) = serde_json::from_str::<Value>(json) else { continue };
        match *tag {
            TAG_TIME_SYNC => {
                // ring-written syncs only: the phone's anchors are not used
                if v["source"].as_str() != Some("phone") {
                    if let Some(unix) = v["unix_time"].as_i64() {
                        anchors.push(Anchor { ds: *ds, unix });
                    }
                }
            }
            TAG_ACTIVITY => {
                if let Some(met) = v["met"].as_array() {
                    acts.push(RingEvent {
                        ds: *ds,
                        steps: v["state"].as_u64().unwrap_or(0).min(255) as u8,
                        met: met.iter().map(|m| met_byte(m.as_f64().unwrap_or(1.0))).collect(),
                    });
                }
            }
            TAG_WEAR => {
                if let Some(state) = v["state"].as_u64() {
                    wear.push(WearEvent { ds: *ds, state: state.min(255) as u8 });
                }
            }
            _ => alerts.push(AlertEvent { ds: *ds, sit: v["alert_type"].as_u64() == Some(1) }),
        }
    }
    compute_stateless(&StatelessInputs {
        anchors: &anchors,
        events: &acts,
        wear: &wear,
        alerts: &alerts,
        newest_ds: None,
        sleeps,
        user,
        tz,
        day_tz: &BTreeMap::new(),
        readiness,
        pad_history: true,
    })
}

pub fn to_json(r: &DayResult) -> Value {
    let s = &r.stats;
    json!({
        "score": r.score,
        "contributors": r.contributors,
        "steps": s.steps,
        "active_kcal": s.active_cal,
        "total_kcal": s.total_cal,
        "eq_distance_m": s.eq_distance,
        "class_min": {
            "rest": s.classes[0], "sedentary": s.classes[1], "light": s.classes[2],
            "moderate": s.classes[3], "vigorous": s.classes[4],
        },
        "non_wear_min": s.non_wear,
        "sit_alerts": s.sit_alerts,
        "target_steps": s.target_steps,
        "target_kcal": s.target_cal,
    })
}
