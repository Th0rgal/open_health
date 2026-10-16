//! The sleep window of a night the ring has not declared yet. The detector chain is
//! `oura_analysis::ported::bedtime_inputs::detect_open`; this module supplies the fallback clock
//! and returns the windows in ring time for `BedPeriod`.

use crate::ring_time::RingClock;
use oura_analysis::ported::bedtime_inputs::detect_open as detect;

/// A detected window in ring time: `(start_ds, end_ds, captured_unix of the newest event)`.
pub type Detected = (i64, i64, i64);

pub fn detect_open(
    events: &[(i64, u8, String, i64)],
    clock: &RingClock,
    tz_hours: f64,
) -> Vec<Detected> {
    let fallback = |ds: i64, cu: i64| (clock.unix_s(ds, cu) * 1000.0).round() as i64;
    let newest_cu = events.iter().map(|e| e.3).max().unwrap_or(0);
    detect(events, tz_hours, &fallback)
        .into_iter()
        .map(|d| (d.start_ds, d.end_ds, newest_cu))
        .collect()
}
