//! Local probe: run the signal stager against the live DB for one night window.
//! Usage: cargo run -p oura-summary --example stage_probe -- START_DS END_DS CAPTURED_UNIX
use std::path::Path;

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let start_ds: i64 = args.first().expect("START_DS").parse().unwrap();
    let end_ds: i64 = args.get(1).expect("END_DS").parse().unwrap();
    let captured: i64 = args.get(2).expect("CAPTURED_UNIX").parse().unwrap();
    let db = Path::new("/Users/meatwad/dev/open_health/oura.db");
    let ranges = vec![[start_ds, end_ds, captured]];
    match oura_summary::stage_nights_from_signals(db, &ranges) {
        Some(v) => println!("{}", serde_json::to_string_pretty(&v).unwrap_or_default()),
        None => println!("None (store open / decoded_events failed)"),
    }
}
