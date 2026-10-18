//! Which sleep stager produces the hypnogram, and the in-process stagers that run it.
//!
//! Two stagers exist, both running on the Rust feature pipeline of open_oura
//! (`oura_analysis::ported::sleepstaging`):
//!
//! * `official`: the vendor classifier (a 2000-tree forest extracted from the vendor library by
//!   `tools/extract_nssa_classifier.py`) in place of the community-trained trees. The file is
//!   proprietary and not part of the repository, so a build can lack it. A client registers
//!   where it found the file ([`register_official_classifier`]); staging then runs in this
//!   process through `vendor_forest::stage_night_forest`. No model runtime is needed.
//! * `xgb`: the same pipeline with a compiled-in community-trained tree ensemble that approximates
//!   the official staging. It needs no files.
//!
//! The choice is stored in `profile.json` as `"sleep_stager": "official" | "xgb"`; an absent key
//! means automatic: official when the classifier is present, otherwise xgb. Every client resolves
//! the choice through [`effective`], and the summary carries [`status`] for rendering.

use crate::ring_time::RingClock;
use crate::{profile_path, stager_inputs, Demographics};
use oura_analysis::ported::sleepstaging::pipeline::{stage_night_default, Inputs, Output, StagingError};
use oura_analysis::ported::sleepstaging::vendor_forest::{stage_night_forest, VendorForest};
use oura_store::Store;
use serde_json::{json, Value};
use std::path::{Path, PathBuf};
use std::sync::{Arc, RwLock};

/// File name of the extracted classifier.
pub const OFFICIAL_CLASSIFIER: &str = "sleepstaging_2_6_0_classifier.bin";
/// Magic bytes of the extracted classifier file.
const CLASSIFIER_MAGIC: &[u8; 8] = b"NSSAFOR1";
/// Bump when the stagers or their cache layout change, so cached hypnograms are recomputed.
const CACHE_VERSION: &str = "r2";

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

/// The registered vendor classifier. `None` until a client registers; a registration whose file
/// is missing, lacks the magic or fails validation holds no forest.
struct Registered {
    path: Option<PathBuf>,
    forest: Option<Arc<VendorForest>>,
}
static OFFICIAL: RwLock<Option<Registered>> = RwLock::new(None);

/// Registers the vendor classifier file. `None`, or a path that is not a valid classifier file,
/// counts as missing. Registering the path that is already loaded keeps the loaded forest.
/// Returns whether the official stager is available.
pub fn register_official_classifier(classifier: Option<&Path>) -> bool {
    let mut guard = OFFICIAL.write().unwrap_or_else(|e| e.into_inner());
    if let (Some(reg), Some(path)) = (guard.as_ref(), classifier) {
        if reg.forest.is_some() && reg.path.as_deref() == Some(path) {
            return true;
        }
    }
    let magic_ok = classifier.is_some_and(|p| {
        use std::io::Read;
        let mut magic = [0u8; 8];
        std::fs::File::open(p)
            .and_then(|mut f| f.read_exact(&mut magic))
            .is_ok()
            && &magic == CLASSIFIER_MAGIC
    });
    let forest = classifier
        .filter(|_| magic_ok)
        .and_then(|p| VendorForest::load(p).ok())
        .map(Arc::new);
    let available = forest.is_some();
    *guard = Some(Registered { path: classifier.map(Path::to_path_buf), forest });
    available
}

/// Whether a valid classifier was registered.
pub fn official_available() -> bool {
    official_forest().is_some()
}

fn official_forest() -> Option<Arc<VendorForest>> {
    OFFICIAL.read().unwrap_or_else(|e| e.into_inner()).as_ref().and_then(|r| r.forest.clone())
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
    let official_notice = (!official).then(|| {
        format!(
            "Not available in this build. Missing: {OFFICIAL_CLASSIFIER}. Extract it with tools/extract_nssa_classifier.py, add it to the models folder, and rebuild, or use the built-in staging."
        )
    });
    json!({
        "choice": chosen.map_or("auto", SleepStager::id),
        "effective": effective.id(),
        "options": [
            {
                "id": "official",
                "label": "Oura model",
                "detail": "The vendor classifier extracted from Oura's sleepstaging_2_6_0, running on this app's Rust feature pipeline. It reproduces the official app's stages closely.",
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
            "Oura model staging is selected but its classifier file is missing, so the built-in staging is used.".to_string()
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

// ── batch stager (web and CLI) ────────────────────────────────────────────────

/// One staging cache per stager, so a switch never reuses the other stager's hypnograms.
fn cache_path(db: &Path, stager: SleepStager) -> PathBuf {
    let name = match stager {
        SleepStager::Official => "official_stage_cache.json",
        SleepStager::Xgb => "xgb_stage_cache.json",
    };
    db.parent().unwrap_or(Path::new(".")).join(name)
}

/// Why [`stage_inputs`] produced no stages.
#[derive(Debug)]
pub enum StageError {
    /// The official stager was asked for but no classifier is registered.
    NoClassifier,
    Staging(StagingError),
}

/// Stages one night with the given stager: the Rust pipeline with rerun after a long wake and
/// the false-nap check, driven by the vendor forest (`official`) or the bundled trees (`xgb`).
pub fn stage_inputs(stager: SleepStager, inputs: &Inputs) -> Result<Output, StageError> {
    match stager {
        SleepStager::Official => {
            let forest = official_forest().ok_or(StageError::NoClassifier)?;
            stage_night_forest(&forest, inputs, true, true).map_err(StageError::Staging)
        }
        SleepStager::Xgb => stage_night_default(inputs, true, true).map_err(StageError::Staging),
    }
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

fn fingerprint(i: &stager_inputs::StagerInputs, stager: SleepStager) -> String {
    let mut h = Fnv::new();
    h.bytes(CACHE_VERSION.as_bytes());
    h.bytes(stager.id().as_bytes());
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

/// Stage codes of one window (1 deep, 2 light, 3 REM, 4 wake per 30 s) and the Unix time in
/// seconds of the first epoch, or `None` when the stager rejects the night.
fn stage_window(i: &stager_inputs::StagerInputs, stager: SleepStager) -> Option<(Vec<i64>, f64)> {
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
    let out = stage_inputs(stager, &inputs).ok()?;
    let stages: Vec<i64> = out.stages.col(0).iter().map(|&x| x.round() as i64).collect();
    let t0 = *out.timestamps_ms.first()? as f64 / 1000.0;
    (!stages.is_empty() && stages.iter().all(|c| (1..=4).contains(c))).then_some((stages, t0))
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

/// Stages every `[start_ds, end_ds, captured_unix]` window with `stager`, returning the batch
/// shape the web dashboard reads (`null` for a window that cannot be staged). The `official`
/// batch carries source `nssa`, the label the brain uses for Oura's own staging, and the time of
/// its first epoch. Results are cached next to the database by input fingerprint.
pub fn stage_nights(db: &Path, sleep_ranges: &[[i64; 3]], demo: &Demographics, stager: SleepStager) -> Option<Value> {
    if stager == SleepStager::Official && !official_available() {
        return None;
    }
    let source = if stager == SleepStager::Official { "nssa" } else { "xgb" };
    let store = Store::open_read_only(db).ok()?;
    let events = store.decoded_events().ok()?;
    let clock = RingClock::from_events(&events);
    let scalars = stager_inputs::profile_scalars(demo.age, demo.height_m, demo.weight_kg, demo.sex);
    let cache_file = cache_path(db, stager);
    let mut cache: serde_json::Map<String, Value> = std::fs::read_to_string(&cache_file)
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
            let key = fingerprint(&inputs, stager);
            used.push(key.clone());
            let cached = cache.get(&key).and_then(|v| {
                let stages: Vec<i64> = v["stages"].as_array()?.iter().filter_map(Value::as_i64).collect();
                Some((stages, v["t0_unix"].as_f64()?))
            });
            let staged = match cached {
                Some(c) => Some(c),
                None => {
                    let staged = stage_window(&inputs, stager);
                    let entry = staged
                        .as_ref()
                        .map_or(json!({ "stages": [], "t0_unix": 0 }), |(s, t0)| json!({ "stages": s, "t0_unix": t0 }));
                    cache.insert(key, entry);
                    dirty = true;
                    staged
                }
            };
            // the window and the stager's epochs must agree, as for the iOS sidecar
            let expected = (end_ds - start_ds) as f64 / 300.0;
            match staged {
                Some((s, t0)) if !s.is_empty() && (s.len() as f64 - expected).abs() <= 2.0 => {
                    let mut h = hypnogram_json(start_ds, end_ds, captured_unix, &s, source);
                    if stager == SleepStager::Official {
                        h["stages_t0_unix"] = json!(t0);
                    }
                    h
                }
                _ => Value::Null,
            }
        })
        .collect();
    if dirty {
        cache.retain(|k, _| used.contains(k));
        let _ = std::fs::write(cache_file, Value::Object(cache).to_string());
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
    fn missing_classifier_falls_back_to_xgb_with_a_notice() {
        let _guard = REGISTRY.lock().unwrap_or_else(|e| e.into_inner());
        let db = temp_db("fallback");
        assert!(!register_official_classifier(None));
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
        assert!(stage_nights(&db, &[[0, 3000, 0]], &Demographics::default(), SleepStager::Official).is_none());
    }

    #[test]
    fn classifier_without_magic_or_with_bad_body_is_missing() {
        let _guard = REGISTRY.lock().unwrap_or_else(|e| e.into_inner());
        let db = temp_db("magic");
        let classifier = db.parent().unwrap().join("c.bin");
        std::fs::write(&classifier, b"garbage!").unwrap();
        assert!(!register_official_classifier(Some(&classifier)));
        // right magic, malformed body: the forest reader rejects it
        std::fs::write(&classifier, b"NSSAFOR1rest").unwrap();
        assert!(!register_official_classifier(Some(&classifier)));
        assert_eq!(effective(&db), SleepStager::Xgb);
    }

    /// With the real classifier (never in the repository), set `OURA_TEST_CLASSIFIER` to its path.
    #[test]
    fn real_classifier_is_the_automatic_default() {
        let Some(path) = std::env::var_os("OURA_TEST_CLASSIFIER") else { return };
        let _guard = REGISTRY.lock().unwrap_or_else(|e| e.into_inner());
        let db = temp_db("present");
        assert!(register_official_classifier(Some(Path::new(&path))));
        assert_eq!(effective(&db), SleepStager::Official);
        set_chosen(&db, Some("xgb")).unwrap();
        assert_eq!(effective(&db), SleepStager::Xgb);
        register_official_classifier(None);
    }
}
