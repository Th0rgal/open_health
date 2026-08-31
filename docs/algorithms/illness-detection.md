# Illness Detection ("Symptom Radar") — on-device model I/O reference

How to feed and read Oura's on-device illness-detection PyTorch model.

- **Model:** `open_oura/notes/models/illness_detection_0_5_1.pt` (decrypted TorchScript).
- **Structure:** 4 sub-modules — `_input_validator`, `_preprocessor`, `_model_runner`,
  `_postprocessor`. Calling the top-level `forward()` runs validator → preprocessor →
  runner → postprocessor and returns the 18-tensor output tuple.
- **Key finding:** feed **raw physiological values**. All normalization, outlier
  dropping, NaN handling, demographic bucketing, calibration and decision thresholds
  live *inside* the model. The Android `ModelInput` builder does nothing but cast
  `double`/`long`→`float` (no scaling) — see
  `SymptomRadarPytorchLiteModel.java:790-922` (`mapDomainToModelInput$lambda$0$*`).

---

## 1. The 23 inputs (in `forward()` order)

`forward()` takes 23 tensors. Inputs 1-9 are 30-day time series of shape **`[30,1]`**
(dtype float32; index 0 = **today / most recent**, index 29 = oldest). Inputs 10-23 are
scalars of shape **`[1,1]`**. Missing days/values are **`NaN`** (Float.NaN) — the model
detects and handles them internally.

| # | forward() arg | Shape | Unit / encoding | Oura source field | Male-user value |
|---|---|---|---|---|---|
| 1 | `average_breath` | [30,1] | breaths/min | nightly sleep avg respiratory rate | real value |
| 2 | `average_heart_rate` | [30,1] | bpm | nightly sleep average HR | real value |
| 3 | `lowest_heart_rate` | [30,1] | bpm | nightly sleep lowest HR | real value |
| 4 | `average_hrv` | [30,1] | ms (RMSSD) | nightly sleep average HRV | real value |
| 5 | `temperature_deviation` | [30,1] | °C vs personal baseline (nightly) | nightly skin-temp deviation | real value |
| 6 | `sedentary_time` | [30,1] | **seconds** | daily activity sedentary seconds | real value |
| 7 | `resting_time` | [30,1] | **seconds** | daily activity resting seconds | real value |
| 8 | `cycle_phase` | [30,1] | menstrual phase code (0 = follicular, else luteal); NaN if none | women's-health cycle phase | **all NaN** |
| 9 | `reason_for_no_cycle_phase` | [30,1] | reason code (2=PREGNANT, 3=CYCLE_TOO_LONG, 5=NOT_ENOUGH_DATA); NaN otherwise | women's-health | **NaN** (any value ignored for males) |
| 10 | `predicted_period_start` | [1,1] | days-until (relative) | women's-health prediction | **NaN** |
| 11 | `predicted_ovulation` | [1,1] | days-until (relative) | women's-health prediction | **NaN** |
| 12 | `age` | [1,1] | years | user settings | real value |
| 13 | `BMI` | [1,1] | kg/m² | user settings (weight/height) | real value |
| 14 | `sex` | [1,1] | **−1 = female, +1 = male, 0 = other/unknown** | `DbUserSettingsUtils.getPytorchValue(BiologicalSex)` | **+1** |
| 15 | `day_of_week` | [1,1] | 0-6 (day-of-week of the analysis day) | analysis date | real value |
| 16 | `resting_hr_avg` | [1,1] | bpm | long-term baseline: restingHrAverage | real value |
| 17 | `resting_hr_dev` | [1,1] | bpm (std dev) | long-term baseline: restingHrDeviation | real value |
| 18 | `hrv_avg` | [1,1] | ms | long-term baseline: hrvAverage | real value |
| 19 | `hrv_dev` | [1,1] | ms (std dev) | long-term baseline: hrvDeviation | real value |
| 20 | `temperature_avg` | [1,1] | °C | long-term baseline: temperatureAverage | real value |
| 21 | `temperature_dev` | [1,1] | °C (std dev) | long-term baseline: longTermTemperatureDeviation | real value |
| 22 | `sedentary_activity_avg` | [1,1] | seconds | long-term baseline: sedentaryActivityAverage | real value |
| 23 | `sedentary_activity_dev` | [1,1] | seconds (std dev) | long-term baseline: sedentaryActivityDeviation | real value |

Sources: input names/order/shapes from `_preprocessor.forward` and `ModelInput`
(`SymptomRadarPytorchLiteModel.java:50-123`). The 8 long-term baselines are the
`LongTermBaselines` domain object `zd0/e.java` (`restingHrAverage, restingHrDeviation,
hrvAverage, hrvDeviation, temperatureAverage, longTermTemperatureDeviation,
sedentaryActivityAverage, sedentaryActivityDeviation`) — the same DbLongTermBaselines
fields (avg + std dev) used elsewhere in the app. `sex` encoding from
`DbUserSettingsUtils.java:272-286` + `GENDER_*` constants (line 32-34); the domain
`Demographics` object is `zd0/d.java` (`age, bmi, sex, dayOfTheWeek`).

> **Important distinction:** the *nightly* `temperature_deviation` time series (#5) is
> the per-night skin-temp deviation from the user's baseline. The *scalar*
> `temperature_avg`/`temperature_dev` (#20/#21) are the **long-term mean and standard
> deviation** of temperature — a different quantity, used only for the temperature
> biomarker range (see §5).

### Internal scaling (informational — do NOT pre-apply)

The `_preprocessor` min-max normalizes each feature (`_normalize`: clip to validation
range → NaN out-of-range → `(x−min)/(max−min)` → `nan_to_num(0.5)`), so out-of-range
and missing values become 0.5. `sex` is first remapped `(sex+1)/2`. Baked-in tables:

- `scalar` `[day_of_week, BMI, age, sex]` min `[0,20,25,−1]` max `[6,35,45,2]`.
- `sleep` `[breath, avg_hr, low_hr, hrv, temp_dev]` scale-min `[13,50,30,15,−0.5]`
  scale-max `[18,80,70,75,0.6]`; validation-min `[0,0,0,0,−7]` validation-max
  `[100,254,254,254,7]`.
- `activity` `[sedentary, resting]` scale-min `[0,20000]` scale-max `[10000,40000]`;
  validation `[1 … 86400]` seconds.

The preprocessor also appends a **missing-data mask** channel = `isnan` of the nightly
temperature-deviation column.

---

## 2. 30-day window orientation & missing-data rule

**Index 0 = today (most recent); index 29 = oldest.** This is the model's own contract,
proven three ways inside the graph:

- `_input_validator.enough_data`: raises **`"301, Error, No temperature deviation for
  today"`** if `temperature_deviation[0]` is NaN → index 0 is *today*.
- Same method: **`"302, Error, More than 7 days of missing temperature deviation over
  last 14 days"`** if `isnan(temperature_deviation[0:14]).sum() > 7` → indices 0-13 are
  the most recent 14 days.
- `_postprocessor.compute_biomarkers`: the "current" value compared each night is
  `sleep_input[0]` (index 0), and the windowed anomaly baseline is `sleep_input[5:]`
  (indices 5-29). Empirically verified: modifying index 0 shifts the compared value;
  the mean/std window is rows 5-29 only.

**Missing days:** encode as `NaN`. `_normalize` maps NaN (and out-of-range) to 0.5 after
scaling; a separate NaN-mask channel is fed to the network; `nanmean`/`nanstd` skip NaN
in biomarker baselines. **Hard requirements:** today's temperature deviation (index 0)
must be present, and at most 7 of the last 14 nights' temperature deviation may be
missing — otherwise the model raises (→ error codes 301/302, surfaced as the
`MISSING_LAST_NIGHT_SLEEP` / `MISSING_SLEEP_DATA` UI states).

**When it runs / which day is "today":** `SymptomRadarCalculationManager` triggers a run
(a) when the **longest-sleep day changes** (`triggerOnLongestSleepChanges`) and (b) on
missing-data changes (`triggerOnMissingData`). "Today" is the latest day that has a
main/longest sleep; that day's data occupies index 0 and its calendar day-of-week feeds
input #15. (Both trigger flows share the same error path that emits an empty list on
throw — `…$triggerOnMissingData$2.java`, `…$triggerOnLongestSleepChanges$6.java`.)

---

## 3. Demographic group (drives calibration curve)

`_postprocessor.determine_demographic_group(sex, cycle_phases, reason_for_no_cycle_phase,
cycle_predictions)` returns one of 4 groups:

| Group | Index | Reached when |
|---|---|---|
| `MALE` | 0 | `cycle_predictions` contains NaN **and** `sex ≥ 0` **and** all `cycle_phases` are NaN |
| `FEMALE_NON_CYCLER` | 1 | no cycle phases, not male, not luteal-condition, and every 5th cycle-phase (`[0::5]`, 5 samples) is NaN |
| `FOLLICULAR` | 2 | valid predictions with `ovulation ≥ 0` and `ovulation ≤ period`; or first non-NaN cycle phase == 0 |
| `LUTEAL` | 3 | valid predictions with `ovulation < 0` or `ovulation > period`; or `reason ∈ {NOT_ENOUGH_DATA=5, CYCLE_TOO_LONG=3, PREGNANT=2}`; or first non-NaN cycle phase ≠ 0 |

**Male path (confirmed empirically → group 0):** pass `cycle_phase` = all NaN,
`reason_for_no_cycle_phase` = NaN, `predicted_period_start`/`predicted_ovulation` = NaN,
`sex` = +1. Note `sex ≥ 0` means `other`(0) with no cycle also maps to MALE.

---

## 4. Calibration → score → decision

1. **`precalibration_prediction`** = raw network output (`_model_runner`), a sigmoid-ish
   probability. Returned as output #17.
2. **`linear_calibration(pred, group)`** = per-group 8-knot piecewise-linear remap →
   **`illness_detection_score`** (output #1, the calibrated 0-1 score shown/stored).
   Tables `target_thresholds` / `slopes` / `intercepts` are `[4 groups × 8]`; for a score
   `p` it finds the segment `thresholds[i] ≤ p ≤ thresholds[i+1]` and returns
   `p*slope[i] + intercept[i]`.
3. **`calc_decision(score)`** with `levels = [0.0, 0.78, 0.85]` → **`illness_detection_
   decision`** (output #2) = highest index `i` where `score ≥ levels[i]`:
   - `score < 0.78` → **0**
   - `0.78 ≤ score < 0.85` → **1**
   - `score ≥ 0.85` → **2**

### decision → risk level → traffic light

`mapModelToDomainOutput$lambda$0` (`SymptomRadarPytorchLiteModel.java:925-935`):

| decision | `IllnessDetectionRiskLevel` | `TrafficLightsState` (`de0/p.java`) |
|---|---|---|
| 0.0 | `BelowThreshold` | `NO_SIGNS` |
| 1.0 | `Low` | `MINOR_SIGNS` |
| 2.0 | `Moderate` | `MAJOR_SIGNS` |

The model **never emits `High`** — the on-device decision has only 3 levels
(`levels.length == 3`). `IllnessDetectionRiskLevel.High` exists in the enum but is a
server-side/unused value; the phone maps only BelowThreshold/Low/Moderate (else → null).
`TrafficLightsState` has exactly 3 states (`de0/i.java`, `de0/o.java`, `de0/p.java`).

---

## 5. Biomarkers → ELEVATED / DECREASED

`compute_biomarkers` emits 7 vectors (outputs #3-#9), each
`[is_out_of_range, value, min_range, max_range]`:

`min_range = mean − threshold·std`, `max_range = mean + threshold·std`. `is_out_of_range`
is **one-sided by `sign`**: `sign ≥ 0` flags only when `value > max_range` (elevated);
`sign ≤ 0` flags only when `value < min_range` (decreased); `sign == 0` flags either side.

| biomarker (output) | sign | threshold (·std) | mean/std source |
|---|---|---|---|
| #3 `average_breath` | 0 (both) | 1.457 | windowed: nanmean/nanstd of days **5-29** |
| #4 `average_heart_rate` | +1 (elevated) | 1.457 | windowed days 5-29 |
| #5 `lowest_heart_rate` | +1 (elevated) | 1.30 | long-term `resting_hr_avg` / `resting_hr_dev` |
| #6 `average_hrv` | −1 (decreased) | 1.11 | windowed days 5-29 |
| #7 `temperature_deviation` | +1 (elevated) | 1.00 | mean = **0**, std = long-term `temperature_dev` |
| #8 `sedentary_time` | +1 (elevated) | 1.50 | long-term `sedentary_activity_avg` / `_dev` |
| #9 `resting_time` | +1 (elevated) | 1.16 | windowed days 5-29 |

The compared `value` is always **today** (index 0). Outputs #10-#16 are the same seven as
`debug_metrics_*` (raw z-scores), #17 `precalibration_prediction`, #18 `demographic_group`.

**UI mapping (`mapModelOutputToBiometrics`, line 989-1001):** a biomarker with any NaN
element → dropped. Otherwise → `Biometric(value=v[1], lowerLimit=v[2], upperLimit=v[3],
indicatesSymptoms = round(v[0]) == 1)`. **ELEVATED vs DECREASED** is decided in the UI at
`yn0/b.java:806`: `value > upperLimit ? ELEVATED : DECREASED`. Only **4** biomarkers are
surfaced as symptom cards (`BiometricType` = `AverageBreath, LowestHeartRate, AverageHrv,
TemperatureDeviation` — `de0/b.java`); avg HR, sedentary and resting time are computed but
not shown as symptoms.

Empirically confirmed sign behavior: lowest-HR today 70 (baseline 51.1-58.9) → flagged
ELEVATED; today 40 → **not** flagged (one-sided high); HRV today 20 → flagged DECREASED;
temp-dev today 1.0 (±0.2) → flagged ELEVATED; breath deviating either way → flagged.

---

## 6. `SymptomRadarStatus` states (`data/utils/SymptomRadarStatus.java`, computed in `data/utils/g.java`)

Given `DbDailyIllnessDetection` (riskLevel + algorithmErrorCode), readiness score, a
"consecutive days" flag, and a GLP-1 early-days integer (1-5):

- No error & riskLevel set:
  - `BelowThreshold` → `NO_SIGNS`
  - `Low` → `MINOR_SIGNS_GLP1` (if GLP1 1-5) / `MINOR_SIGNS_AND_READINESS_HIGH` (readiness
    ≥ **85**) / `MINOR_SIGNS_FOR_CONSECUTIVE_DAYS` (consecutive flag) / else `MINOR_SIGNS`
  - `Moderate` → analogous `MAJOR_SIGNS_GLP1` / `MAJOR_SIGNS_AND_READINESS_HIGH` /
    `MAJOR_SIGNS_FOR_CONSECUTIVE_DAYS` / else `MAJOR_SIGNS`
- riskLevel null or error code set:
  - error **301** → `MISSING_LAST_NIGHT_SLEEP`
  - error **302** → `MISSING_SLEEP_DATA`
  - else → `UNEXPECTED_ERROR`
- `CALIBRATING` and `SIGNS_PREGNANCY_MODE_NO_ONBOARDING` are set by other flows
  (onboarding/calibration state), not by this mapper.

(Error codes 301/302 are exactly the exceptions raised by the model's
`_input_validator.enough_data`.)

---

## 7. Minimal worked example (healthy 35-year-old male)

```python
import torch
m = torch.jit.load("illness_detection_0_5_1.pt").eval()
nan = float("nan")
def col(v): return torch.tensor([[float(v)]]*30, dtype=torch.float32)  # index0 = today
def sc(v):  return torch.tensor([[float(v)]],   dtype=torch.float32)

out = m(
    col(15.0),   # 1 average_breath (br/min)
    col(60.0),   # 2 average_heart_rate (bpm)
    col(55.0),   # 3 lowest_heart_rate (bpm)
    col(45.0),   # 4 average_hrv (ms)
    col(0.0),    # 5 temperature_deviation (°C, nightly)   <-- index0 must be non-NaN
    col(30000.0),# 6 sedentary_time (s)
    col(28000.0),# 7 resting_time (s)
    col(nan),    # 8 cycle_phase           (male: all NaN)
    col(nan),    # 9 reason_for_no_cycle   (male: NaN)
    sc(nan),     # 10 predicted_period_start (male: NaN)
    sc(nan),     # 11 predicted_ovulation    (male: NaN)
    sc(35), sc(24), sc(1), sc(3),          # 12 age, 13 BMI, 14 sex=+1(male), 15 day_of_week
    sc(55), sc(3), sc(45), sc(6),          # 16-19 resting_hr avg/dev, hrv avg/dev
    sc(36), sc(0.2), sc(30000), sc(4000),  # 20-23 temp avg/dev, sedentary avg/dev
)
score, decision = out[0].item(), out[1].item()
# -> demographic_group (out[17]) == 0.0 (MALE); score ~0.57 -> decision 0 (BelowThreshold / NO_SIGNS)
```

To trip a symptom: set `out`'s temperature-deviation series index 0 to e.g. `1.0` (with
`temperature_dev` baseline `0.2`) → `biomarker_temperature_deviation = [1, 1.0, −0.2, 0.2]`
→ ELEVATED (value 1.0 > upperLimit 0.2).

---

## 8. Source map

- Model I/O contract & sub-module code: introspected from
  `open_oura/notes/models/illness_detection_0_5_1.pt` (`_input_validator`,
  `_preprocessor`, `_postprocessor` `.code`).
- `…/symptomradar/model/pytorch/SymptomRadarPytorchLiteModel.java` — ModelInput/Output,
  `mapDomainToModelInput` (raw cast, no scaling), decision→riskLevel, biomarker→Biometric.
- `ek0/d.java` (time-series `[N,1]` tensor via `Tensor.fromBlob`), `ek0/e.java` (scalar
  `[1,1]`, default NaN).
- `zd0/d.java` (Demographics), `zd0/e.java` (LongTermBaselines), `zd0/g.java` (5 sleep
  series), `com/…/model/db/…/DbUserSettingsUtils.java:272` (sex→pytorch value),
  `com/ouraring/core/utils/k.java:887` (`Long`→float, NaN if null).
- `de0/p.java`,`de0/i.java`,`de0/o.java` (riskLevel→TrafficLightsState), `de0/a.java`
  (Biometric), `de0/b.java` (BiometricType/SymptomReason when-maps), `yn0/b.java:806`
  (ELEVATED/DECREASED = value > upperLimit).
- `com/…/symptomradar/ui/components/{TrafficLightsState,SymptomReason,BiometricType}.java`.
- `com/…/symptomradar/data/utils/SymptomRadarStatus.java` + `g.java` (status mapping,
  readiness ≥ 85, error 301/302).
- `SymptomRadarCalculationManager$triggerOn{LongestSleepChanges,MissingData}*.java`.
