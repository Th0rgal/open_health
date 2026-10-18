//! Which sleep stager produces the hypnogram, and the tree-ensemble stager that is always present.
//!
//! Two stagers exist:
//!
//! * `official`: Oura's `sleepstaging_2_6_0` TorchScript graph together with the classifier
//!   extracted from the vendor library (`tools/extract_nssa_classifier.py`). Both files are
//!   proprietary and not part of the repository, so a build can lack them. The clients run it
//!   (web: `tools/run_sleep_model.py`, iOS: `TorchBridge`) and register here which files they found.
//! * `xgb`: the Rust pipeline of open_oura (`oura_analysis::ported::sleepstaging`) with a
//!   compiled-in community-trained tree ensemble that approximates the official staging. It needs no files.
//!
//! The choice is stored in `profile.json` as `"sleep_stager": "official" | "xgb"`; an absent key
//! means automatic: official when its files are present, otherwise xgb. Every client resolves
//! the choice through [`effective`], and the summary carries [`status`] for rendering.

use crate::ring_time::RingClock;
use crate::{profile_path, stager_inputs, Demographics};
use oura_analysis::ported::sleepstaging::pipeline::{stage_night_default, Inputs};
use oura_store::Store;
use serde_json::{json, Value};
use std::path::{Path, PathBuf};
use std::sync::RwLock;

/// Display name of the vendor graph, as the notice lists it.
pub const OFFICIAL_GRAPH: &str = "sleepstaging_2_6_0";
/// File name of the extracted classifier.
pub const OFFICIAL_CLASSIFIER: &str = "sleepstaging_2_6_0_classifier.bin";
/// Magic bytes of the extracted classifier file.
const CLASSIFIER_MAGIC: &[u8; 8] = b"NSSAFOR1";
/// Bump when the xgb pipeline or its classifier changes, so cached hypnograms are recomputed.
const XGB_CACHE_VERSION: &str = "xgb-r1";

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SleepStager {
    Official,
    Xgb,
}

impl SleepStager {
    pub fn id(self) -> &'static str {
        match self {
            SleepStager::Official => "official",
            SleepStager::Xgb => "xgb",
        }
    }

    pub fn from_id(id: &str) -> Option<Self> {
        match id {
            "official" => Some(SleepStager::Official),
            "xgb" => Some(SleepStager::Xgb),
            _ => None,
        }
    }
}

/// Files of the official stager that a client reported missing; empty once both are present.
/// `None` until a client registers (a client without the official runner never does).
static OFFICIAL_MISSING: RwLock<Option<Vec<String>>> = RwLock::new(None);

/// Registers the official stager's files. `graph` is the TorchScript file the client would load,
/// `classifier` the extracted forest; `None` or a path that does not point to a valid file counts
/// as missing. Returns whether the official stager is available.
pub fn register_official_files(graph: Option<&Path>, classifier: Option<&Path>) -> bool {
    let mut missing = Vec::new();
    if !graph.is_some_and(|p| std::fs::metadata(p).is_ok_and(|m| m.is_file() && m.len() > 0)) {
        missing.push(OFFICIAL_GRAPH.to_string());
    }
    let classifier_ok = classifier.is_some_and(|p| {
        use std::io::Read;
        let mut magic = [0u8; 8];
        std::fs::File::open(p)
            .and_then(|mut f| f.read_exact(&mut magic))
            .is_ok()
            && &magic == CLASSIFIER_MAGIC
    });
    if !classifier_ok {
        missing.push(OFFICIAL_CLASSIFIER.to_string());
    }
    let available = missing.is_empty();
    *OFFICIAL_MISSING.write().unwrap_or_else(|e| e.into_inner()) = Some(missing);
    available
}

/// Whether the official stager's files were registered and are all present.
pub fn official_available() -> bool {
    OFFICIAL_MISSING
        .read()
        .unwrap_or_else(|e| e.into_inner())
        .as_ref()
        .is_some_and(|m| m.is_empty())
}

fn official_missing() -> Vec<String> {
    OFFICIAL_MISSING
        .read()
        .unwrap_or_else(|e| e.into_inner())
        .clone()
        .filter(|m| !m.is_empty())
        .unwrap_or_else(|| vec![OFFICIAL_GRAPH.to_string(), OFFICIAL_CLASSIFIER.to_string()])
}

/// The stager stored in `profile.json`, or `None` for automatic.
pub fn chosen(db: &Path) -> Option<SleepStager> {
    let v: Value = serde_json::from_str(&std::fs::read_to_string(profile_path(db)).ok()?).ok()?;
    SleepStager::from_id(v["sleep_stager"].as_str()?)
}

/// The stager that runs: the chosen one when it is available, otherwise official when its files
/// are present, otherwise xgb.
pub fn effective(db: &Path) -> SleepStager {
    match chosen(db) {
        Some(SleepStager::Xgb) => SleepStager::Xgb,
        Some(SleepStager::Official) | None if official_available() => SleepStager::Official,
        _ => SleepStager::Xgb,
    }
}

/// What the clients render: the stored choice, the stager in use, and both options with their
/// availability and a notice for an option that cannot be used.
pub fn status(db: &Path) -> Value {
    let chosen = chosen(db);
    let effective = effective(db);
    let official = official_available();
    let missing = official_missing();
    let official_notice = (!official).then(|| {
        format!(
            "Not available in this build. Missing: {}. Add them to the models folder and rebuild, or use the built-in staging.",
            missing.join(", ")
        )
    });
    json!({
        "choice": chosen.map_or("auto", SleepStager::id),
        "effective": effective.id(),
        "options": [
            {
                "id": "official",
                "label": "Official",
                "detail": "Oura's sleepstaging_2_6_0 graph with its extracted classifier, the stager behind the official app's hypnogram.",
                "available": official,
                "notice": official_notice,
            },
            {
                "id": "xgb",
                "label": "Built-in",
                "detail": "A community-trained tree ensemble that approximates the official staging. It needs no model files, so it is always available.",
                "available": true,
                "notice": Value::Null,
            },
        ],
        // set when the stored choice cannot run and another stager is used instead
        "notice": (chosen == Some(SleepStager::Official) && !official).then(|| {
            "Official staging is selected but its model files are missing, so the built-in staging is used.".to_string()
        }),
    })
}

/// Stores the choice: `"official"` or `"xgb"`; any other value (such as `"auto"`) removes it.
pub fn set_chosen(db: &Path, id: Option<&str>) -> anyhow::Result<()> {
    let mut profile = std::fs::read_to_string(profile_path(db))
        .ok()
        .and_then(|s| serde_json::from_str::<Value>(&s).ok())
        .filter(Value::is_object)
        .unwrap_or_else(|| json!({}));
    match id.and_then(SleepStager::from_id) {
        Some(stager) => profile["sleep_stager"] = json!(stager.id()),
        None => {
            profile.as_object_mut().map(|o| o.remove("sleep_stager"));
        }
    }
    std::fs::write(profile_path(db), serde_json::to_vec_pretty(&profile)?)?;
    Ok(())
}

// ── xgb batch stager (web and CLI) ────────────────────────────────────────────

fn cache_path(db: &Path) -> PathBuf {
    db.parent().unwrap_or(Path::new(".")).join("xgb_stage_cache.json")
}

/// FNV-1a over the bytes of the stager inputs, so an unchanged night is not staged again.
struct Fnv(u64);
impl Fnv {
    fn new() -> Self {
        Fnv(0xcbf29ce484222325)
    }
    fn bytes(&mut self, b: &[u8]) {
        for &x in b {
            self.0 = (self.0 ^ x as u64).wrapping_mul(0x100000001b3);
        }
    }
    fn i64(&mut self, v: i64) {
        self.bytes(&v.to_le_bytes());
    }
    fn f32(&mut self, v: f32) {
        self.bytes(&v.to_le_bytes());
    }
}

fn fingerprint(i: &stager_inputs::StagerInputs) -> String {
    let mut h = Fnv::new();
    h.bytes(XGB_CACHE_VERSION.as_bytes());
    h.i64(i.start_ms);
    h.i64(i.end_ms);
    for (t, a, b, c) in &i.beats {
        h.i64(*t);
        [*a, *b, *c].into_iter().for_each(|v| h.f32(v));
    }
    for (t, row) in &i.acm {
        h.i64(*t);
        row.iter().for_each(|v| h.f32(*v));
    }
    for (t, v) in &i.temp {
        h.i64(*t);
        h.f32(*v);
    }
    i.scalars.iter().for_each(|v| h.f32(*v));
    format!("{:016x}", h.0)
}

/// Stage codes of one window with the bundled classifier (1 deep, 2 light, 3 REM, 4 wake per 30 s),
/// or `None` when the stager rejects the night.
fn stage_window(i: &stager_inputs::StagerInputs) -> Option<Vec<i64>> {
    let acm_ts: Vec<i64> = i.acm.iter().map(|a| a.0).collect();
    let acm: Vec<[f32; 6]> = i.acm.iter().map(|a| a.1).collect();
    let beat_ts: Vec<i64> = i.beats.iter().map(|b| b.0).collect();
    let beats: Vec<[f32; 3]> = i.beats.iter().map(|b| [b.1, b.2, b.3]).collect();
    let temp_ts: Vec<i64> = i.temp.iter().map(|t| t.0).collect();
    let temp: Vec<f32> = i.temp.iter().map(|t| t.1).collect();
    let inputs = Inputs {
        acm_values: &acm,
        acm_timestamps: &acm_ts,
        ibi_values: &beats,
        ibi_timestamps: &beat_ts,
        temp_values: &temp,
        temp_timestamps: &temp_ts,
        scalars: i.scalars,
        bedtime: [i.start_ms, i.end_ms],
    };
    let out = stage_night_default(&inputs, true, true).ok()?;
    let stages: Vec<i64> = out.stages.col(0).iter().map(|&x| x.round() as i64).collect();
    (!stages.is_empty() && stages.iter().all(|c| (1..=4).contains(c))).then_some(stages)
}

/// The batch JSON of a staged window, in the shape `run_sleep_model.py --batch` returns.
pub fn hypnogram_json(start_ds: i64, end_ds: i64, captured_unix: i64, stages: &[i64], source: &str) -> Value {
    let share = |code: i64| {
        let n = stages.iter().filter(|&&c| c == code).count();
        (n as f64 / stages.len() as f64 * 1000.0).round() / 10.0
    };
    let asleep = stages.iter().filter(|&&c| (1..=3).contains(&c)).count();
    json!({
        "start_ds": start_ds,
        "end_ds": end_ds,
        "captured_unix": captured_unix,
        "stages": stages,
        "deep_pct": share(1),
        "light_pct": share(2),
        "rem_pct": share(3),
        "wake_pct": share(4),
        "efficiency_pct": (asleep as f64 / stages.len() as f64 * 1000.0).round() / 10.0,
        "source": source,
    })
}

/// Stages every `[start_ds, end_ds, captured_unix]` window with the xgb pipeline, returning the same
/// batch shape as `run_sleep_model.py` (`null` for a window that cannot be staged). Results are
/// cached next to the database by input fingerprint.
pub fn stage_nights_xgb(db: &Path, sleep_ranges: &[[i64; 3]], demo: &Demographics) -> Option<Value> {
    let store = Store::open_read_only(db).ok()?;
    let events = store.decoded_events().ok()?;
    let clock = RingClock::from_events(&events);
    let scalars = stager_inputs::profile_scalars(demo.age, demo.height_m, demo.weight_kg, demo.sex);
    let mut cache: serde_json::Map<String, Value> = std::fs::read_to_string(cache_path(db))
        .ok()
        .and_then(|s| serde_json::from_str::<Value>(&s).ok())
        .and_then(|v| v.as_object().cloned())
        .unwrap_or_default();
    let mut used = Vec::with_capacity(sleep_ranges.len());
    let mut dirty = false;
    let results: Vec<Value> = sleep_ranges
        .iter()
        .map(|&[start_ds, end_ds, captured_unix]| {
            let Ok(inputs) = stager_inputs::collect(&events, &clock, start_ds, end_ds, captured_unix, scalars) else {
                return Value::Null;
            };
            let key = fingerprint(&inputs);
            used.push(key.clone());
            let stages: Option<Vec<i64>> = match cache.get(&key) {
                Some(v) => v.as_array().map(|a| a.iter().filter_map(Value::as_i64).collect()),
                None => {
                    let staged = stage_window(&inputs);
                    cache.insert(key, json!(staged.clone().unwrap_or_default()));
                    dirty = true;
                    staged
                }
            };
            // the window and the stager's epochs must agree, as for the iOS sidecar
            let expected = (end_ds - start_ds) as f64 / 300.0;
            match stages {
                Some(s) if !s.is_empty() && (s.len() as f64 - expected).abs() <= 2.0 => {
                    hypnogram_json(start_ds, end_ds, captured_unix, &s, "xgb")
                }
                _ => Value::Null,
            }
        })
        .collect();
    if dirty {
        cache.retain(|k, _| used.contains(k));
        let _ = std::fs::write(cache_path(db), Value::Object(cache).to_string());
    }
    Some(Value::Array(results))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Mutex;

    /// The registration is process-global, so tests that set it run one at a time.
    static REGISTRY: Mutex<()> = Mutex::new(());

    fn temp_db(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("oura-stager-{name}-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        dir.join("oura.db")
    }

    #[test]
    fn choice_round_trips_and_auto_clears_it() {
        let db = temp_db("choice");
        assert_eq!(chosen(&db), None);
        set_chosen(&db, Some("xgb")).unwrap();
        assert_eq!(chosen(&db), Some(SleepStager::Xgb));
        set_chosen(&db, Some("official")).unwrap();
        assert_eq!(chosen(&db), Some(SleepStager::Official));
        set_chosen(&db, Some("auto")).unwrap();
        assert_eq!(chosen(&db), None);
    }

    #[test]
    fn missing_official_files_fall_back_to_xgb_with_a_notice() {
        let _guard = REGISTRY.lock().unwrap_or_else(|e| e.into_inner());
        let db = temp_db("fallback");
        assert!(!register_official_files(None, None));
        assert_eq!(effective(&db), SleepStager::Xgb);
        set_chosen(&db, Some("official")).unwrap();
        assert_eq!(effective(&db), SleepStager::Xgb);
        let s = status(&db);
        assert_eq!(s["choice"], "official");
        assert_eq!(s["effective"], "xgb");
        assert_eq!(s["options"][0]["available"], false);
        assert!(s["options"][0]["notice"].as_str().unwrap().contains(OFFICIAL_CLASSIFIER));
        assert!(s["notice"].is_string());
        assert_eq!(s["options"][1]["available"], true);
    }

    #[test]
    fn present_official_files_are_the_automatic_default() {
        let _guard = REGISTRY.lock().unwrap_or_else(|e| e.into_inner());
        let db = temp_db("present");
        let dir = db.parent().unwrap();
        let graph = dir.join("g.ptl");
        let classifier = dir.join("c.bin");
        std::fs::write(&graph, b"graph").unwrap();
        std::fs::write(&classifier, b"NSSAFOR1rest").unwrap();
        assert!(register_official_files(Some(&graph), Some(&classifier)));
        assert_eq!(effective(&db), SleepStager::Official);
        set_chosen(&db, Some("xgb")).unwrap();
        assert_eq!(effective(&db), SleepStager::Xgb);
        // a classifier without the magic does not count
        std::fs::write(&classifier, b"garbage!").unwrap();
        assert!(!register_official_files(Some(&graph), Some(&classifier)));
        assert_eq!(status(&db)["options"][0]["notice"].as_str().map(|n| n.contains(OFFICIAL_CLASSIFIER)), Some(true));
    }
}
