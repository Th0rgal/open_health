#ifndef OURA_TORCH_BRIDGE_H
#define OURA_TORCH_BRIDGE_H
#include <stdint.h>
#include <sqlite3.h> // surfaced to Swift via the bridging header (no SQLite3 module needed)

#ifdef __cplusplus
extern "C" {
#endif

// Cardiovascular age (cva_2_1_5): forward(ppg [n_segs×1500] f32, demo [1×5] f32) →
// (vascular_age, …, pwv, …). `ppg` is row-major; `demo` is [sex(-1/0/1), height_m,
// age, ring, weight]. Writes vascular_age + pulse-wave velocity; returns 0 / -1.
int oura_cva(const char *model_path, const float *ppg, int n_segs, const float *demo,
             double *out_vascular_age, double *out_pwv);

// Activity sessions (automatic_activity_detection): mirrors run_activity_model.py's
// forward(context[4], user[14], met[n_met×2], step[n_step×12], motion[n_motion×9],
//   temp[n_temp×2], hr[n_hr×2], None, None, threshold, min_duration, 0.0). Writes
// workouts row-major into out_workouts (max_rows × 9 =
// [start_min, end_min, is_workout, id1,p1, id2,p2, id3,p3]); returns rows / -1.
// Last activity/step-decoder error on this thread; copy before the next call.
const char *oura_activity_last_error(void);

int oura_activity(const char *model_path, const float *context, const float *user,
                  const float *met, int n_met, const float *step, int n_step,
                  const float *motion, int n_motion,
                  const float *temp, int n_temp, const float *hr, int n_hr,
                  float threshold, float min_duration, float *out_workouts, int max_rows);

// Illness detection ("Symptom Radar", illness_detection_0_5_1). Mirrors
// tools/run_illness_model.py. `series` is row-major 7×30 (index 0 = today, NaN =
// missing): average_breath, average_heart_rate, lowest_heart_rate, average_hrv,
// temperature_deviation, sedentary_time(s), resting_time(s). `scalars` is 12 values:
// age, BMI, sex(-1/+1/0), day_of_week, then the 8 long-term baselines
// (resting_hr avg/dev, hrv avg/dev, temperature avg/dev, sedentary avg/dev). The
// menstrual-cycle inputs are fed as NaN internally (male/no-cycle path -> group 0).
// Writes the calibrated score and decision (0/1/2), and 4 shown biomarkers as
// [is_out, value, lower, upper] × {breath, lowest_hr, hrv, temp} into
// out_biomarkers (16 floats). Returns 0 / -1.
int oura_illness(const char *model_path, const float *series, const float *scalars,
                 double *out_score, int *out_decision, float *out_biomarkers);
// Free every loaded model module (they reload on next use). Waits for a running
// inference to finish, so call it off the main thread.
void oura_torch_release(void);
#ifdef __cplusplus
}
#endif
#endif
