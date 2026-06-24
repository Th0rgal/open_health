#!/usr/bin/env python3
"""Run Oura's decrypted automatic_activity_detection model on our stored ring data.

Feeds met/motion/temperature/heartrate timeseries (from the SQLite event log)
into the TorchScript AutomaticActivityDetectionModel and prints detected
activity/workout segments. stepmotion (stride features) is stubbed NaN — we have
no source for it — so step-based sport discrimination is weaker (flagged).

Usage: python tools/run_activity_model.py [DB] [TZ_OFFSET_HOURS]
"""
import sys, json, sqlite3, datetime
import torch

DB = sys.argv[1] if len(sys.argv) > 1 else "captures/ring5.db"
TZ = int(sys.argv[2]) if len(sys.argv) > 2 else 1  # Lisbon = UTC+1 (summer)
MODEL = "notes/models/automatic_activity_detection_3_1_11.pt"

BEHAVIOR = {
    -1: "nothing", 0: "<empty>", 1: "badminton", 2: "boxing", 3: "crossCountrySkiing",
    4: "crossTraining", 5: "cycling", 6: "dance", 7: "elliptical", 8: "strengthTraining",
    9: "hockey", 10: "pilates", 11: "rowing", 12: "running", 13: "swimming", 14: "walking",
    15: "yoga", 16: "golf", 17: "tennis", 18: "climbing", 19: "downhillSkiing",
    20: "snowboarding", 21: "hiking", 22: "horsebackRiding", 23: "volleyball", 24: "basketball",
    25: "americanFootball", 26: "soccer", 27: "baseball", 28: "coreExercise", 29: "cricket",
    30: "HIIT", 31: "diving", 32: "fitnessClass", 33: "floorball", 34: "gymnastics",
    35: "handball", 36: "houseWork", 37: "iceSkating", 38: "jumpingRope", 39: "martialArts",
    40: "flexibility", 41: "mountainBiking", 42: "nordicWalking", 48: "stairExercise",
    49: "stretching", 50: "surfing", 51: "waterFitness", 52: "yardwork", 53: "padel",
    69: "skateboarding", 65535: "other", 65536: "nap", 65537: "sleep",
    65538: "pause", 70937: "meditation", 71201: "eating", 71227: "relax", 71239: "transport",
}

# ---- load events, anchor ring deciseconds to wall-clock via captured_unix ----
con = sqlite3.connect(DB)
rows = con.execute(
    "SELECT ring_timestamp, tag, decoded_json, captured_unix FROM events "
    "WHERE decoded_json IS NOT NULL ORDER BY ring_timestamp"
).fetchall()
max_ds, anchor_unix = max(((r[0], r[3]) for r in rows), key=lambda x: x[0])
min_ds = min(r[0] for r in rows)
def _unix_min(ds):
    return (anchor_unix - (max_ds - ds) / 10.0) / 60.0
# Rebase by whole days: keeps time-of-day (model uses min%1440) but keeps values
# small enough to be EXACT in float32 (unix-minutes ~29.7M exceed 2^24 precision).
OFFSET = int(_unix_min(min_ds) // 1440) * 1440
def tmin(ds):
    return int(round(_unix_min(ds))) - OFFSET

met, motion, temp, hr = [], [], [], []
for ds, tag, js, _ in rows:
    try:
        v = json.loads(js)
    except Exception:
        continue
    t = tmin(ds)
    if tag == 0x50 and isinstance(v.get("met"), list):
        for i, m in enumerate(v["met"]):
            met.append((t + i, float(m)))
    elif tag == 0x47:
        import os
        s = float(os.environ.get("ACM_SCALE", "1"))
        motion.append((t,
            float(v.get("orientation", 0)), float(v.get("motion_seconds", 0)),
            v.get("avg_x", 0) * s, v.get("avg_y", 0) * s, v.get("avg_z", 0) * s,
            float("nan"),  # regular_motion: no source
            float(v.get("low_intensity", 0)), float(v.get("high_intensity", 0))))
    elif tag == 0x46 and v.get("temps_c"):
        temp.append((t, float(v["temps_c"][0])))
    elif tag == 0x80 and v.get("hr_bpm"):
        b = v["hr_bpm"]
        if b:
            hr.append((t, sum(b) / len(b)))

# dedupe met by minute (keep last), sort each series
met = sorted({round(t): (t, m) for t, m in met}.values())
def f32(seq):
    return torch.tensor(seq, dtype=torch.float32)
met_t, motion_t = f32(met), f32(sorted(motion))
temp_t, hr_t = f32(sorted(temp)), f32(sorted(hr))
# stepmotion stub: NaN features but spanning the FULL time range, else its last
# timestamp caps the model's last_valid_time and truncates every series.
step_t = torch.full((2, 12), float("nan"), dtype=torch.float32)
step_t[0, 0] = met_t[0, 0]
step_t[1, 0] = met_t[-1, 0]

def rng(t, name):
    if len(t) == 0:
        print(f"  {name}: EMPTY"); return
    print(f"  {name}: {len(t)} rows  [{int(t[0,0])}..{int(t[-1,0])}] min")
print("series time ranges (unix minutes):")
for t, n in [(met_t, "met"), (motion_t, "motion"), (temp_t, "temp"), (hr_t, "hr")]:
    rng(t, n)

# context + user
d = datetime.datetime.utcfromtimestamp(anchor_unix + TZ * 3600)
context = torch.tensor([d.year, d.month, d.day, d.weekday()], dtype=torch.float32)
user = torch.tensor([30, 1, 1.78, 78] + [float("nan")] * 10, dtype=torch.float32)

m = torch.jit.load(MODEL, map_location="cpu").eval()
with torch.no_grad():
    workouts, _, segments = m(
        context, user, met_t, step_t, motion_t, temp_t, hr_t,
        None, None, torch.tensor(0.5), torch.tensor(5.0), torch.tensor(0.0))

def hhmm(minute):
    return datetime.datetime.utcfromtimestamp((minute + OFFSET) * 60 + TZ * 3600).strftime("%m-%d %H:%M")

# workouts[n,9] = [start_min, end_min, is_workout_prob, id1,p1, id2,p2, id3,p3]
print(f"\n{workouts.shape[0]} activity segment(s) detected:\n")
print(f"  {'when (local)':<18} {'dur':>4} {'wk?':>5}  top-3 type (activity:prob)")
for w in workouts.tolist():
    start, end, is_wk = w[0], w[1], w[2]
    top = "  ".join(f"{BEHAVIOR.get(int(w[3+2*k]), int(w[3+2*k]))}:{w[4+2*k]:.2f}" for k in range(3))
    print(f"  {hhmm(start)}-{hhmm(end)[-5:]:<6} {end-start:>3.0f}m {is_wk:>5.2f}  {top}")
