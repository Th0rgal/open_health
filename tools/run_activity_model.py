#!/usr/bin/env python3
"""Run Oura automatic_activity_detection 3.1.11 with Android-parity inputs.

The official Android app evaluates one local calendar day at a time and feeds
the 12-column step-motion series produced by steps_motion_decoder. Those details
are essential: omitting or misordering gait can turn a hike into cycling.
"""
import argparse
import datetime
import json
import os
import sqlite3
import sys
import warnings
from pathlib import Path

import torch

from _common import resolve_db, resolve_models_dir
from activity_features import decoder_to_aad, unpack_real_step
from epoch_time import build_epochs, make_unix_s

warnings.filterwarnings("ignore", message=".*searchsorted.*")

REPO = Path(__file__).resolve().parent.parent
MODEL_NAME = "automatic_activity_detection_3_1_11.pt"
MODEL = resolve_models_dir(REPO, MODEL_NAME) / MODEL_NAME
STEP_MODEL = MODEL.parent / "steps_motion_decoder_2_0_0.pt"
MODEL_VERSION = "3.1.11"

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
    69: "skateboarding", 65535: "other", 65536: "nap", 65537: "sleep", 65538: "pause",
    70937: "meditation", 71201: "eating", 71227: "relax", 71239: "transport",
}


def parse_args():
    parser = argparse.ArgumentParser(description="Label activities with Oura's AAD model.")
    parser.add_argument("db", nargs="?", default=None)
    parser.add_argument("--tz", type=float, default=1.0, help="Fixed UTC offset in hours (default 1)")
    parser.add_argument("--threshold", type=float, default=0.5)
    parser.add_argument("--min-duration", type=float, default=10.0,
                        help="Minimum segment minutes; Android default is 10")
    parser.add_argument("--date", help="Only process one local day (YYYY-MM-DD)")
    parser.add_argument("--no-stepmotion", action="store_true", help="Diagnostic fallback without gait")
    parser.add_argument("--json", action="store_true")
    parser.add_argument("--verbose", action="store_true")
    args, extra = parser.parse_known_args()
    if extra:
        try:
            args.tz = float(extra[0])
        except (ValueError, IndexError):
            pass
    if args.db is not None and not Path(args.db).exists():
        try:
            args.tz = float(args.db)
            args.db = None
        except ValueError:
            pass
    # Retain the old debugging switch, but real gait is now the safe default.
    if os.environ.get("STEPMOTION") == "0":
        args.no_stepmotion = True
    return args


def tensor(rows, columns, required=True):
    if rows:
        return torch.tensor(rows, dtype=torch.float32)
    if required:
        return torch.tensor([[0.0] + [float("nan")] * (columns - 1)], dtype=torch.float32)
    return torch.empty((0, columns), dtype=torch.float32)


def decode_stepmotion(db, unix_seconds, enabled):
    if not enabled or not STEP_MODEL.exists():
        return []
    packets = db.execute(
        "SELECT ring_timestamp, tag, body, captured_unix FROM events "
        "WHERE tag IN (126,127) AND body IS NOT NULL ORDER BY captured_unix,id"
    ).fetchall()
    seconds = {}
    for ds, tag, body, captured in packets:
        if tag == 0x7F and len(body) == 14:
            wall_ds = round(unix_seconds(ds, captured) * 10)
            seconds[wall_ds] = body
    raw, timestamps = [], []
    for ds, tag, body, captured in packets:
        if tag != 0x7E or len(body) != 14:
            continue
        wall_ds = round(unix_seconds(ds, captured) * 10)
        second = seconds.get(wall_ds + 1)
        if second is None:
            continue
        raw.append(unpack_real_step(body, second))
        timestamps.append(wall_ds * 100)
    if not raw:
        return []
    decoder = torch.jit.load(str(STEP_MODEL), map_location="cpu").eval()
    with torch.no_grad():
        out_ts, out_data = decoder(torch.tensor(timestamps, dtype=torch.int64),
                                   torch.tensor(raw, dtype=torch.float32))
    # Keep all three 10-second sub-windows, as Android's TimeseriesDbStepMotion does.
    return sorted((ts / 60_000.0, decoder_to_aad(values))
                  for ts, values in zip(out_ts.flatten().tolist(), out_data.tolist()))


def run_day(model, day, day_start_min, signals, steps, args):
    day_end_min = day_start_min + 24 * 60

    def select(name):
        return sorted(([t - day_start_min] + values for t, values in signals[name]
                       if day_start_min <= t < day_end_min), key=lambda row: row[0])

    # The ring may resend a MET minute; Android's Realm series has one value per timestamp.
    met_by_minute = {round(row[0]): row for row in select("met")}
    met = sorted(met_by_minute.values(), key=lambda row: row[0])
    if not met:
        return []
    motion, temperature, heart_rate = select("motion"), select("temperature"), select("heart_rate")
    step_rows = [[t - day_start_min] + values for t, values in steps
                 if day_start_min <= t < day_end_min]
    lo, hi = met[0][0], met[-1][0]
    step_rows = [[lo] + [float("nan")] * 11] + step_rows + [[hi] + [float("nan")] * 11]

    context = torch.tensor([day.year, day.month, day.day, day.weekday()], dtype=torch.float32)
    user = torch.tensor([30, 1, 1.78, 78] + [float("nan")] * 10, dtype=torch.float32)
    with torch.no_grad():
        workouts, _, _ = model(
            context, user, tensor(met, 2), tensor(step_rows, 12), tensor(motion, 9),
            tensor(temperature, 2), tensor(heart_rate, 2), None, None,
            torch.tensor(args.threshold), torch.tensor(args.min_duration), torch.tensor(0.0),
        )

    sessions = []
    local_midnight = datetime.datetime.combine(day, datetime.time())
    for row in workouts.tolist():
        start = local_midnight + datetime.timedelta(minutes=row[0])
        end = local_midnight + datetime.timedelta(minutes=row[1])
        top = [(BEHAVIOR.get(int(row[3 + 2 * i]), str(int(row[3 + 2 * i]))),
                round(row[4 + 2 * i], 3)) for i in range(3)]
        sessions.append({
            "start": start.strftime("%Y-%m-%d %H:%M"), "end": end.strftime("%H:%M"),
            "duration_min": round(row[1] - row[0]), "is_workout": round(row[2], 3),
            "label": top[0][0], "label_confidence": top[0][1], "top3": top,
        })
    return sessions


def main():
    args = parse_args()
    db_path = resolve_db(args.db, REPO)
    if not MODEL.exists():
        sys.exit(f"error: model not found: {MODEL}")
    db = sqlite3.connect(str(db_path))
    rows = db.execute(
        "SELECT ring_timestamp,tag,decoded_json,captured_unix FROM events "
        "WHERE decoded_json IS NOT NULL ORDER BY captured_unix,id"
    ).fetchall()
    if not rows:
        sys.exit(f"error: no decoded events in {db_path}")
    unix_seconds = make_unix_s(build_epochs(rows))
    signals = {name: [] for name in ("met", "motion", "temperature", "heart_rate")}
    scale = float(os.environ.get("ACM_SCALE", "1"))
    for ds, tag, payload, captured in rows:
        try:
            value = json.loads(payload)
        except Exception:
            continue
        # Ring summaries are minute buckets. Epoch reconstruction can leave them a
        # few seconds off the boundary; Android stores the bucket timestamp itself.
        minute = round(unix_seconds(ds, captured) / 60)
        if tag == 0x50 and isinstance(value.get("met"), list):
            signals["met"].extend((minute + i, [float(v)]) for i, v in enumerate(value["met"]))
        elif tag == 0x47:
            signals["motion"].append((minute, [
                float(value.get("orientation", 0)), float(value.get("motion_seconds", 0)),
                float(value.get("avg_x", 0)) * scale, float(value.get("avg_y", 0)) * scale,
                float(value.get("avg_z", 0)) * scale, float("nan"),
                float(value.get("low_intensity", 0)), float(value.get("high_intensity", 0)),
            ]))
        elif tag == 0x46 and value.get("temps_c"):
            signals["temperature"].append((minute, [float(value["temps_c"][0])]))
        elif tag == 0x80 and value.get("hr_bpm"):
            bpm = value["hr_bpm"]
            signals["heart_rate"].append((minute, [sum(bpm) / len(bpm)]))
    if not signals["met"]:
        sys.exit("no MET events in DB — cannot run activity model")

    steps = decode_stepmotion(db, unix_seconds, not args.no_stepmotion)
    offset_minutes = args.tz * 60
    dates = sorted({datetime.datetime.utcfromtimestamp(t * 60 + args.tz * 3600).date()
                    for t, _ in signals["met"]})
    if args.date:
        dates = [datetime.date.fromisoformat(args.date)]
    model = torch.jit.load(str(MODEL), map_location="cpu").eval()
    sessions = []
    for day in dates:
        utc_midnight = datetime.datetime.combine(day, datetime.time()) - datetime.timedelta(minutes=offset_minutes)
        day_start_min = utc_midnight.replace(tzinfo=datetime.timezone.utc).timestamp() / 60
        try:
            sessions.extend(run_day(model, day, day_start_min, signals, steps, args))
        except (torch.jit.Error, RuntimeError) as error:
            if args.verbose:
                print(f"{day}: model rejected incomplete day ({error})", file=sys.stderr)
    result = {"model": MODEL_VERSION, "pipeline": "android-parity", "sessions": sessions}
    if args.json:
        print(json.dumps(result, indent=2))
        return
    print(f"Activity sessions — Oura AAD v{MODEL_VERSION}, Android-parity inputs\n")
    if not sessions:
        print("  No activity segments detected.")
        return
    print(f"  {'date':<10} {'time':<13} {'dur':>4}  {'workout':>7}  activity (model confidence)")
    for session in sessions:
        date, start = session["start"].split(" ")
        alternatives = "   ".join(f"{name} {prob:.2f}" for name, prob in session["top3"][1:])
        mark = "✓" if session["is_workout"] >= args.threshold else " "
        print(f"  {date:<10} {start}-{session['end']:<8} {session['duration_min']:>3}m  "
              f"{session['is_workout']:.2f} {mark}  {session['label']} "
              f"{session['label_confidence']:.2f}   ·   {alternatives}")


if __name__ == "__main__":
    main()
