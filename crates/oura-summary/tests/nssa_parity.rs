//! Parity of the Rust staging inputs with the vendor-derived reference values in
//! `apps/ios/OuraApp/Tests/NssaParityFixture.json` (written by `tools/make_nssa_fixture.py` from
//! a fixed seed, no ring data). The fixture covers input building and IBI correction. The
//! fixture fields without a Rust counterpart are listed in `docs/algorithms/sleep-staging.md`.

use oura_analysis::ported::ibi_correction::correct_ibis;
use oura_protocol::events::decode_event_body;
use oura_summary::aggregate_30s_to_5min;
use serde_json::Value;

fn fixture() -> Value {
    let path = concat!(env!("CARGO_MANIFEST_DIR"), "/../../apps/ios/OuraApp/Tests/NssaParityFixture.json");
    serde_json::from_str(&std::fs::read_to_string(path).expect("fixture")).expect("fixture json")
}

fn bytes(v: &Value) -> Vec<u8> {
    v.as_array().unwrap().iter().map(|x| x.as_u64().unwrap() as u8).collect()
}

#[test]
fn acm_period_decode_matches_in_model_order() {
    let f = fixture();
    let cases = f["acm"].as_array().unwrap();
    assert_eq!(cases.len(), 40);
    for c in cases {
        let decoded = decode_event_body(0x72, &bytes(&c["body"])).expect("decodes");
        let m = decoded["acm_mad"].as_array().unwrap();
        // the stager input order is [madIqr, madMax, madTmean, faIqr, faMax, faMean], which is
        // the decoder's output reversed (see `sleepstaging::events::collect`)
        let got: Vec<f32> = (0..6).map(|i| m[5 - i].as_f64().unwrap() as f32).collect();
        for (g, w) in got.iter().zip(c["values"].as_array().unwrap()) {
            // the decoder rounds to 4 decimals
            let w = w.as_f64().unwrap() as f32;
            assert!((g - w).abs() <= 1e-4 * w.abs().max(1.0), "{g} vs {w}");
        }
    }
    // a body shorter than 12 bytes does not decode
    assert!(decode_event_body(0x72, &[0u8; 11]).is_none());
}

#[test]
fn sleep_temperature_decode_matches() {
    let f = fixture();
    for c in f["temp"].as_array().unwrap() {
        let decoded = decode_event_body(0x75, &bytes(&c["body"])).expect("decodes");
        let temps = decoded["temps_c"].as_array().unwrap();
        let want = c["samples"].as_array().unwrap();
        assert_eq!(temps.len(), want.len());
        for (g, w) in temps.iter().zip(want) {
            assert_eq!(g.as_f64().unwrap() as f32, w[1].as_f64().unwrap() as f32);
        }
        // consecutive samples are 30 s apart, as `sleepstaging::events::collect` places them
        let ts: Vec<i64> = w_ts(want);
        assert!(ts.windows(2).all(|p| p[1] - p[0] == 30_000));
    }
}

fn w_ts(samples: &[Value]) -> Vec<i64> {
    samples.iter().map(|s| s[0].as_i64().unwrap()).collect()
}

#[test]
fn ibi_correction_matches_the_vendor_port() {
    let f = fixture();
    let streams = f["ibi_correction"].as_array().unwrap();
    assert_eq!(streams.len(), 6);
    for s in streams {
        let raw: Vec<(u64, u16, u16)> = s["raw"]
            .as_array()
            .unwrap()
            .iter()
            .map(|b| (b[0].as_u64().unwrap(), b[1].as_u64().unwrap() as u16, b[2].as_u64().unwrap() as u16))
            .collect();
        let want: Vec<[i64; 4]> = s["corrected"]
            .as_array()
            .unwrap()
            .iter()
            .map(|b| [0, 1, 2, 3].map(|i| b[i].as_i64().unwrap()))
            .collect();
        let got: Vec<[i64; 4]> = correct_ibis(&raw)
            .iter()
            .map(|e| [e.ts as i64, e.ibi as i64, e.amp as i64, e.validity as i64])
            .collect();
        assert_eq!(got.len(), want.len());
        assert_eq!(got, want);
    }
}

#[test]
fn five_minute_aggregation_matches() {
    let f = fixture();
    for c in f["aggregate_5min"].as_array().unwrap() {
        let stages: Vec<i64> = c["stages"].as_array().unwrap().iter().map(|x| x.as_i64().unwrap()).collect();
        let want: Vec<i64> = c["five_min"].as_array().unwrap().iter().map(|x| x.as_i64().unwrap()).collect();
        assert_eq!(aggregate_30s_to_5min(&stages), want);
    }
    assert_eq!(aggregate_30s_to_5min(&[2, 2, 2, 2, 2, 2, 4, 4, 4, 4]), vec![4]);
    assert_eq!(aggregate_30s_to_5min(&[2, 2, 2, 1, 1, 1, 4, 4, 3, 3]), vec![1]);
}
