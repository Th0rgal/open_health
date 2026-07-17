// Objective-C++ bridge: run SleepNet (moonstone) through the LibTorch lite
// interpreter on iOS. Mirrors the input order of tools/run_sleep_model.py:
//   forward(bedtime, ibi_val, ibi_ts, acm_val, acm_ts, temp_val, temp_ts,
//           spo2_val, spo2_ts, scalars, tst)
// and reads stages from output tuple element 1, column 0 (staging[:, 0]).
#import "TorchBridge.h"
#include <torch/csrc/jit/mobile/import.h>
#include <torch/csrc/jit/mobile/module.h>
#include <ATen/ATen.h>
#include <algorithm>
#include <cmath>
#include <limits>
#include <memory>
#include <string>
#include <vector>

static at::Tensor blobLong(const int64_t *p, int64_t n) {
    return at::from_blob((void *)p, {n}, at::kLong).clone();
}
static at::Tensor blobFloat2d(const float *p, int64_t rows, int64_t cols) {
    return at::from_blob((void *)p, {rows, cols}, at::kFloat).clone();
}

int oura_sleepnet(const char *model_path,
                  const int64_t *ibi_ts, const float *ibi_val, int n_ibi,
                  const int64_t *acm_ts, const float *acm_val, int n_acm,
                  const int64_t *temp_ts, const float *temp_val, int n_temp,
                  int64_t bedtime_start_ms, int64_t bedtime_end_ms,
                  int *out_stages, int max_out) {
    try {
        auto m = torch::jit::_load_for_mobile(std::string(model_path), c10::nullopt);

        auto ibi_ts_t = blobLong(ibi_ts, n_ibi);
        auto ibi_val_t = blobFloat2d(ibi_val, n_ibi, 3);
        auto acm_ts_t = blobLong(acm_ts, n_acm);
        auto acm_val_t = blobFloat2d(acm_val, n_acm, 1);
        auto temp_ts_t = blobLong(temp_ts, n_temp);
        auto temp_val_t = blobFloat2d(temp_val, n_temp, 1);

        int64_t bt[2] = {bedtime_start_ms, bedtime_end_ms};
        auto bedtime = blobLong(bt, 2);
        auto spo2_val = at::empty({0, 1}, at::kFloat);
        auto spo2_ts = at::empty({0}, at::kLong);
        float sc[5] = {35.f, 25.f, 0.f, 0.f, 0.f};
        auto scalars = at::from_blob(sc, {5}, at::kFloat).clone();
        float tstv[1] = {300.f};
        auto tst = at::from_blob(tstv, {1}, at::kFloat).clone();

        std::vector<c10::IValue> inputs{bedtime, ibi_val_t, ibi_ts_t, acm_val_t, acm_ts_t,
                                        temp_val_t, temp_ts_t, spo2_val, spo2_ts, scalars, tst};
        auto out = m.forward(inputs).toTuple();
        auto staging = out->elements()[1].toTensor();           // [epochs, channels]
        auto col0 = staging.select(1, 0).to(at::kInt).contiguous();
        int n = std::min<int>((int)col0.numel(), max_out);
        const int *acc = col0.data_ptr<int>();
        for (int i = 0; i < n; i++) out_stages[i] = acc[i];
        return n;
    } catch (const std::exception &e) {
        return -1;
    }
}

int oura_cva(const char *model_path, const float *ppg, int n_segs, const float *demo,
             double *out_vascular_age, double *out_pwv) {
    try {
        auto m = torch::jit::_load_for_mobile(std::string(model_path), c10::nullopt);
        auto ppg_t = blobFloat2d(ppg, n_segs, 1500);
        auto demo_t = blobFloat2d(demo, 1, 5);
        auto out = m.forward({ppg_t, demo_t}).toTuple();
        // (daily_cva, quality, raw_quality, daily_pwv, ppg_segment_metrics)
        *out_vascular_age = out->elements()[0].toTensor().item<double>();
        *out_pwv = out->elements()[3].toTensor().item<double>();
        return 0;
    } catch (const std::exception &e) {
        return -1;
    }
}

static at::Tensor mat(const float *p, int rows, int cols) {
    return rows > 0 ? blobFloat2d(p, rows, cols) : at::empty({0, cols}, at::kFloat);
}

int oura_activity(const char *model_path, const float *context, const float *user,
                  const float *met, int n_met, const float *step, int n_step,
                  const float *motion, int n_motion,
                  const float *temp, int n_temp, const float *hr, int n_hr,
                  float threshold, float min_duration, float *out_workouts, int max_rows) {
    try {
        // ActivityModel calls once per retained local day. Loading the 15 MB module
        // for every day dominated sync time, so retain it for the process lifetime.
        static std::unique_ptr<torch::jit::mobile::Module> cached;
        static std::string cached_path;
        if (!cached || cached_path != model_path) {
            cached = std::make_unique<torch::jit::mobile::Module>(
                torch::jit::_load_for_mobile(std::string(model_path), c10::nullopt));
            cached_path = model_path;
        }
        auto &m = *cached;
        auto context_t = at::from_blob((void *)context, {4}, at::kFloat).clone();
        auto user_t = at::from_blob((void *)user, {14}, at::kFloat).clone();
        auto met_t = mat(met, n_met, 2);
        auto motion_t = mat(motion, n_motion, 9);
        auto temp_t = mat(temp, n_temp, 2);
        auto hr_t = mat(hr, n_hr, 2);

        auto step_t = mat(step, n_step, 12);

        auto thr = at::full({}, threshold, at::kFloat);   // 0-dim scalars
        auto mind = at::full({}, min_duration, at::kFloat);
        auto zero = at::full({}, 0.f, at::kFloat);
        std::vector<c10::IValue> inputs{context_t, user_t, met_t, step_t, motion_t, temp_t, hr_t,
                                        c10::IValue(), c10::IValue(), thr, mind, zero};
        auto out = m.forward(inputs).toTuple();
        auto workouts = out->elements()[0].toTensor().to(at::kFloat).contiguous();
        int n = std::min<int>((int)workouts.size(0), max_rows);
        const float *wp = workouts.data_ptr<float>();
        for (int i = 0; i < n * 9; i++) out_workouts[i] = wp[i];
        return n;
    } catch (const std::exception &e) {
        return -1;
    }
}

int oura_stepmotion(const char *model_path, const int64_t *timestamps_ms,
                    const float *raw, int n_raw, int64_t *out_timestamps_ms,
                    float *out_features, int max_rows) {
    try {
        static std::unique_ptr<torch::jit::mobile::Module> cached;
        static std::string cached_path;
        if (!cached || cached_path != model_path) {
            cached = std::make_unique<torch::jit::mobile::Module>(
                torch::jit::_load_for_mobile(std::string(model_path), c10::nullopt));
            cached_path = model_path;
        }
        auto &m = *cached;
        auto timestamps = blobLong(timestamps_ms, n_raw);
        auto data = blobFloat2d(raw, n_raw, 27);
        auto result = m.forward({timestamps, data}).toTuple();
        auto out_ts = result->elements()[0].toTensor().reshape({-1}).to(at::kLong).contiguous();
        auto out_data = result->elements()[1].toTensor().to(at::kFloat).contiguous();
        int n = std::min<int>((int)out_data.size(0), max_rows);
        const int64_t *tp = out_ts.data_ptr<int64_t>();
        const float *fp = out_data.data_ptr<float>();
        for (int i = 0; i < n; i++) out_timestamps_ms[i] = tp[i];
        for (int i = 0; i < n * 11; i++) out_features[i] = fp[i];
        return n;
    } catch (const std::exception &e) {
        return -1;
    }
}

int oura_illness(const char *model_path, const float *series, const float *scalars,
                 double *out_score, int *out_decision, float *out_biomarkers) {
    try {
        static std::unique_ptr<torch::jit::mobile::Module> cached;
        static std::string cached_path;
        if (!cached || cached_path != model_path) {
            cached = std::make_unique<torch::jit::mobile::Module>(
                torch::jit::_load_for_mobile(std::string(model_path), c10::nullopt));
            cached_path = model_path;
        }
        auto &m = *cached;
        const float nan = std::numeric_limits<float>::quiet_NaN();
        // 7 daily series -> [30,1] columns (index 0 = today)
        auto colf = [&](int k) { return blobFloat2d(series + k * 30, 30, 1); };
        auto nanCol = at::full({30, 1}, nan, at::kFloat);   // cycle_phase / reason (male)
        auto sc = [&](float v) { return at::full({1, 1}, v, at::kFloat); };
        // scalars: 0 age,1 bmi,2 sex,3 dow, 4-11 baselines
        std::vector<c10::IValue> inputs{
            colf(0), colf(1), colf(2), colf(3), colf(4), colf(5), colf(6),  // 1-7 series
            nanCol, nanCol,                                                 // 8-9 cycle/reason
            sc(nan), sc(nan),                                               // 10-11 period/ovulation
            sc(scalars[0]), sc(scalars[1]), sc(scalars[2]), sc(scalars[3]), // 12-15 age,bmi,sex,dow
            sc(scalars[4]), sc(scalars[5]), sc(scalars[6]), sc(scalars[7]), // 16-19 rhr/hrv avg+dev
            sc(scalars[8]), sc(scalars[9]), sc(scalars[10]), sc(scalars[11])}; // 20-23 temp/sed avg+dev
        auto out = m.forward(inputs).toTuple();
        auto &el = out->elements();
        *out_score = el[0].toTensor().item<double>();
        *out_decision = (int)std::lround(el[1].toTensor().item<double>());
        // 4 shown biomarkers: output indices 2(breath) 4(lowest_hr) 5(hrv) 6(temp)
        const int idx[4] = {2, 4, 5, 6};
        for (int b = 0; b < 4; b++) {
            auto v = el[idx[b]].toTensor().to(at::kFloat).contiguous();
            const float *vp = v.data_ptr<float>();
            for (int j = 0; j < 4; j++) out_biomarkers[b * 4 + j] = vp[j]; // [is_out,value,min,max]
        }
        return 0;
    } catch (const std::exception &e) {
        return -1;
    }
}
