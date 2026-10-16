//! Night breathing rate from the ring's inter-beat intervals, using the ported
//! breathing rate averages (`oura_analysis::ported::breathing_rate`).

use oura_analysis::ported::breathing_rate::breathing_rate;

const EPOCH_S: f64 = 30.0;

/// One beat: wall-clock milliseconds and interval in milliseconds.
pub type Beat = (i64, u16);

/// Lays the intervals of one event back to back so the last beat ends at the event stamp.
pub fn beats_from_event(stamp_s: f64, ibi_ms: &[u16], keep: impl Fn(usize) -> bool) -> Vec<Beat> {
    let mut t = (stamp_s * 1000.0).round() as i64;
    let mut out = Vec::with_capacity(ibi_ms.len());
    for (k, &ibi) in ibi_ms.iter().enumerate().rev() {
        if keep(k) {
            out.push((t, ibi));
        }
        t -= ibi as i64;
    }
    out.reverse();
    out
}

/// `(breaths/min, variability, heart rate)` for a night from `start_s` to `end_s`.
/// `motion` holds `(stamp_s, motion_seconds)` points; each 30 s epoch takes the largest.
/// `None` when the night is shorter than the library's 3 h minimum or yields no record.
pub fn night(start_s: f64, end_s: f64, beats: &[Beat], motion: &[(f64, f64)]) -> Option<(f64, f64, f64)> {
    let epochs = ((end_s - start_s) / EPOCH_S).floor() as usize;
    if epochs < 361 {
        return None;
    }
    let mut m = vec![0u8; epochs];
    for &(t, s) in motion {
        let i = ((t - start_s) / EPOCH_S).floor();
        if i >= 0.0 && (i as usize) < epochs {
            m[i as usize] = m[i as usize].max(s.round().clamp(0.0, 255.0) as u8);
        }
    }
    let lo = (start_s * 1000.0) as i64 - 60_000;
    let hi = (end_s * 1000.0) as i64 + 60_000;
    let mut sel: Vec<Beat> = beats.iter().copied().filter(|b| b.0 >= lo && b.0 <= hi).collect();
    sel.sort_by_key(|b| b.0);
    let ibi: Vec<u16> = sel.iter().map(|b| b.1).collect();
    let ts: Vec<i64> = sel.iter().map(|b| b.0).collect();
    let (rate, var, hr) = breathing_rate((start_s * 1000.0).round() as i64, &ibi, &ts, &m);
    (rate > 0.0).then_some((rate as f64, var as f64, hr as f64))
}
