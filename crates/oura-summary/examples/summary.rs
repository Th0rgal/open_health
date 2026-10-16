//! Print the dashboard summary for a database file — the SAME `build_summary()` JSON
//! the iOS app renders, computed on the desktop.
//!
//! The point is debugging an app that lives on a phone: pull or export its `oura.db`,
//! run this, and you see exactly what the app sees (model-free — the on-device torch
//! panels stay null, everything signal-derived is identical).
//!
//! ```sh
//! cargo run -p oura-summary --example summary -- /path/to/oura.db 3
//! cargo run -p oura-summary --example summary -- /path/to/oura.db 3 hourly_hr
//! ```
//! The optional third argument prints the hourly heart-rate aggregation instead.

use std::path::Path;

fn main() {
    // `OURA_STEP_COUNTER=/path/step_counter_1_3_0.bin` installs the step counter's weights
    if let Ok(path) = std::env::var("OURA_STEP_COUNTER") {
        eprintln!("step counter loaded: {}", oura_summary::real_steps::load_step_counter(&path));
    }
    let mut args = std::env::args().skip(1);
    let db = match args.next() {
        Some(path) => path,
        None => {
            eprintln!("usage: summary <oura.db> [tz_offset_hours] [hourly_hr]");
            std::process::exit(2);
        }
    };
    let tz: i64 = args
        .next()
        .and_then(|v| v.parse().ok())
        .unwrap_or(0);
    let what = args.next().unwrap_or_default();

    let value = if what == "hourly_hr" {
        oura_summary::hourly_hr::hourly_hr(Path::new(&db), tz, 0)
    } else {
        oura_summary::build_summary(Path::new(&db), tz, &oura_summary::NoModelRunner)
    };
    match value {
        Ok(v) => println!("{}", serde_json::to_string_pretty(&v).unwrap()),
        Err(e) => {
            eprintln!("error: {e}");
            std::process::exit(1);
        }
    }
}
