//! Inputs of the sleep stager for one bedtime window. The assembly from decoded events
//! is `oura_analysis::ported::sleepstaging::events`; this module adds the part that depends on
//! this crate's ring clock: refusing windows that cannot be dated, and placing events captured
//! before the first ring `time_sync`.

use crate::ring_time::{ClockSource, RingClock};

pub use oura_analysis::ported::sleepstaging::events::{profile_scalars, AppClock, StagerInputs};

/// Assembles one window. `events` is `Store::decoded_events()`; `captured_unix` is the capture
/// time of the window's `bedtime_period` event.
pub fn collect(
    events: &[(i64, u8, String, i64)],
    clock: &RingClock,
    start_ds: i64,
    end_ds: i64,
    captured_unix: i64,
    scalars: [f32; 3],
) -> Result<StagerInputs, String> {
    for ds in [start_ds, end_ds] {
        if clock.resolve(ds, captured_unix).source == ClockSource::Undated {
            return Err("sleep window clock is undated or ambiguous".into());
        }
    }
    oura_analysis::ported::sleepstaging::events::collect(
        events,
        &|ds, cu| clock.unix_s(ds, cu),
        start_ds,
        end_ds,
        captured_unix,
        scalars,
    )
}
