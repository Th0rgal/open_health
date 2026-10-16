// Objective-C++ bridge: run Oura's models through the LibTorch lite interpreter on
// iOS: activity, step-motion, cardiovascular age, illness, and the NSSA sleep stager
// (sleepstaging_2_6_0, mirroring tools/nssa_stager.py):
//   forward(acm_values, acm_ts, ibi_values, ibi_ts, temp_values, temp_ts, scalars, bedtime)
// with its five oura_ops custom ops registered below on top of NssaOps.c. Our own
// tree-ensemble stager is not here: it is open_oura's Rust port.
#import "TorchBridge.h"
#include "NssaOps.h"
#include <torch/library.h>
#import <Foundation/Foundation.h>
#include <torch/csrc/jit/mobile/import.h>
#include <torch/csrc/jit/mobile/module.h>
#include <ATen/ATen.h>
#include <algorithm>
#include <cmath>
#include <cstdio>
#include <limits>
#include <memory>
#include <mutex>
#include <string>
#include <vector>

// LibTorch lite is not safe to call concurrently. Hiking days (large tensors)
// plus four models used to race here and abort the process.
static std::mutex g_torch;

// One loaded module per model, reused across calls (ActivityModel calls once per
// day) and dropped by oura_torch_release() once a model pass is over. Kept for the
// process lifetime, they held ~280 MB while the app sat suspended, where iOS
// terminates the largest apps first under memory pressure.
struct ModuleSlot {
    std::unique_ptr<torch::jit::mobile::Module> module;
    std::string path;
};
static ModuleSlot g_nssa, g_cva, g_activity, g_illness;

void oura_torch_release(void) {
    std::lock_guard<std::mutex> lock(g_torch);
    for (ModuleSlot *slot : {&g_nssa, &g_cva, &g_activity, &g_illness}) {
        slot->module.reset();
        slot->path.clear();
    }
}

static torch::jit::mobile::Module &cachedModule(const char *path,
                                                std::unique_ptr<torch::jit::mobile::Module> &slot,
                                                std::string &slotPath) {
    if (!slot || slotPath != path) {
        slot = std::make_unique<torch::jit::mobile::Module>(
            torch::jit::_load_for_mobile(std::string(path), c10::nullopt));
        slotPath = path;
    }
    return *slot;
}

static at::Tensor blobLong(const int64_t *p, int64_t n) {
    if (n <= 0) return at::empty({0}, at::kLong);
    return at::from_blob((void *)p, {n}, at::kLong).clone();
}
static at::Tensor blobFloat2d(const float *p, int64_t rows, int64_t cols) {
    if (rows <= 0) return at::empty({0, cols}, at::kFloat);
    return at::from_blob((void *)p, {rows, cols}, at::kFloat).clone();
}

// ---- NSSA (sleepstaging_2_6_0): Oura's custom ops, implemented on NssaOps.c ------
// Schemas match tools/nssa_ops.py; the .ptl calls them by name through the dispatcher.
static std::mutex g_classifier_lock;
static std::vector<uint8_t> g_classifier_blob;
static std::string g_classifier_path;

void oura_nssa_set_classifier_path(const char *path) {
    std::lock_guard<std::mutex> lock(g_classifier_lock);
    if (path && g_classifier_path != path) {
        g_classifier_path = path;
        g_classifier_blob.clear();
    }
}

static const std::vector<uint8_t> &classifierBlob() {
    std::lock_guard<std::mutex> lock(g_classifier_lock);
    if (g_classifier_blob.empty() && !g_classifier_path.empty()) {
        FILE *f = fopen(g_classifier_path.c_str(), "rb");
        if (f) {
            fseek(f, 0, SEEK_END);
            long n = ftell(f);
            fseek(f, 0, SEEK_SET);
            if (n > 0) {
                g_classifier_blob.resize((size_t)n);
                if (fread(g_classifier_blob.data(), 1, (size_t)n, f) != (size_t)n) g_classifier_blob.clear();
            }
            fclose(f);
        }
    }
    return g_classifier_blob;
}

static std::tuple<at::Tensor, at::Tensor> op_create_windows(const at::Tensor &timestamps, double window_s) {
    auto ts = timestamps.reshape({-1}).to(at::kLong).contiguous();
    const int64_t n_ts = ts.numel();
    if (n_ts == 0) return {at::zeros({0, 1}, at::kLong), at::full({0, 4}, -1, at::kLong)};
    const int64_t n = std::max<int64_t>(0, nssa_create_windows(ts.data_ptr<int64_t>(), n_ts, window_s, nullptr, nullptr));
    auto wts = at::zeros({n}, at::kLong);
    auto rows = at::full({n, 4}, -1, at::kLong);
    if (n > 0) nssa_create_windows(ts.data_ptr<int64_t>(), n_ts, window_s, wts.data_ptr<int64_t>(), rows.data_ptr<int64_t>());
    return {wts.reshape({-1, 1}), rows};
}

static at::Tensor op_find_indices(const at::Tensor &x, const at::Tensor &xnew) {
    auto xs = x.reshape({-1}).to(at::kLong).contiguous();
    auto vs = xnew.reshape({-1}).to(at::kLong).contiguous();
    auto out = at::zeros({vs.numel()}, at::kLong);
    if (nssa_find_indices(xs.data_ptr<int64_t>(), xs.numel(), vs.data_ptr<int64_t>(), vs.numel(),
                          out.data_ptr<int64_t>()) != 0)
        throw std::runtime_error("oura_find_indices: native code would read past x");
    return out.reshape(xnew.sizes());
}

static at::Tensor op_biquad_cascade(const at::Tensor &sos, const at::Tensor &x) {
    auto s = sos.to(at::kFloat).contiguous();
    auto v = x.to(at::kFloat).reshape({-1}).contiguous();
    auto out = at::empty_like(v);
    if (s.size(0) > 64) throw std::runtime_error("oura_biquad_cascade: too many sections");
    nssa_biquad_cascade(s.data_ptr<float>(), s.size(0), v.data_ptr<float>(), v.numel(), out.data_ptr<float>());
    return out.reshape(x.sizes()).to(x.scalar_type());
}

static at::Tensor op_find_peaks(const at::Tensor &x) {
    auto v = x.to(at::kFloat).reshape({-1}).contiguous();
    auto out = at::zeros({std::max<int64_t>(v.numel() / 2, 1)}, at::kLong);
    const int64_t m = nssa_find_peaks(v.data_ptr<float>(), v.numel(), out.data_ptr<int64_t>());
    return out.slice(0, 0, m).clone();
}

static at::Tensor op_sleep_classifier(const at::Tensor &features) {
    auto f = features.to(at::kFloat).contiguous();
    if (f.dim() != 2 || f.size(1) != 182) throw std::runtime_error("oura_sleep_classifier expects [N,182]");
    const auto &blob = classifierBlob();
    if (blob.empty()) throw std::runtime_error("oura_sleep_classifier: classifier blob missing");
    auto out = at::empty({f.size(0), 4}, at::kFloat);
    if (f.size(0) > 0 &&
        nssa_classifier_predict(blob.data(), (int64_t)blob.size(), f.data_ptr<float>(), f.size(0), f.size(1),
                                out.data_ptr<float>()) != 0)
        throw std::runtime_error("oura_sleep_classifier: bad classifier blob");
    return out;
}

// The lite build ships no Conjugate/Negative fallbacks, yet NSSA's graph routes a
// few real-valued ops (numpy_T + mul in its smoothing) through those keys. Real
// tensors never carry the conj/neg bits, so passing through is exact.
TORCH_LIBRARY_IMPL(_, Conjugate, m) { m.fallback(torch::CppFunction::makeFallthrough()); }
TORCH_LIBRARY_IMPL(_, Negative, m) { m.fallback(torch::CppFunction::makeFallthrough()); }

TORCH_LIBRARY(oura_ops, m) {
    m.def("oura_create_windows(Tensor timestamps, float window_s) -> (Tensor, Tensor)", op_create_windows);
    m.def("oura_find_indices(Tensor x, Tensor xnew) -> Tensor", op_find_indices);
    m.def("oura_biquad_cascade(Tensor sos, Tensor x) -> Tensor", op_biquad_cascade);
    m.def("oura_find_peaks(Tensor x) -> Tensor", op_find_peaks);
    m.def("oura_sleep_classifier(Tensor features) -> Tensor", op_sleep_classifier);
}

int oura_nssa(const char *model_path,
              const int64_t *acm_ts, const float *acm_val, int n_acm,
              const int64_t *ibi_ts, const float *ibi_val, int n_ibi,
              const int64_t *temp_ts, const float *temp_val, int n_temp,
              const float *demographics, int64_t bedtime_start_ms, int64_t bedtime_end_ms,
              int *out_stages, int64_t *out_timestamps_ms, int max_out) {
    if (!model_path || !demographics || !out_stages || !out_timestamps_ms || max_out <= 0
        || n_acm <= 0 || n_ibi <= 0 || n_temp <= 0) return -1;
    std::lock_guard<std::mutex> lock(g_torch);
    try {
        auto &m = cachedModule(model_path, g_nssa.module, g_nssa.path);
        int64_t bt[2] = {bedtime_start_ms, bedtime_end_ms};
        std::vector<c10::IValue> inputs{
            blobFloat2d(acm_val, n_acm, 6), blobLong(acm_ts, n_acm),
            blobFloat2d(ibi_val, n_ibi, 3), blobLong(ibi_ts, n_ibi),
            at::from_blob((void *)temp_val, {n_temp}, at::kFloat).clone(), blobLong(temp_ts, n_temp),
            at::from_blob((void *)demographics, {3}, at::kFloat).clone(), blobLong(bt, 2)};
        auto out = m.forward(inputs).toTuple();
        auto stages = out->elements()[1].toTensor();               // [epochs, 1 + 4 probs]
        if (stages.dim() < 2 || stages.size(1) < 1) {
            NSLog(@"oura_nssa: unexpected stage shape");
            return -1;
        }
        auto col0 = stages.select(1, 0).to(at::kDouble).round().to(at::kInt).contiguous();
        auto timestamps = out->elements()[0].toTensor().to(at::kLong).reshape({-1}).contiguous();
        if (timestamps.numel() != col0.numel() || col0.numel() > max_out) {
            NSLog(@"oura_nssa: mismatched timestamps or output exceeds buffer");
            return -1;
        }
        const int n = (int)col0.numel();
        const int64_t *ts = timestamps.data_ptr<int64_t>();
        const int *acc = col0.data_ptr<int>();
        for (int i = 0; i < n; i++) { out_timestamps_ms[i] = ts[i]; out_stages[i] = acc[i]; }
        return n;
    } catch (const std::exception &e) {
        NSLog(@"oura_nssa: %s", e.what());
        return -1;
    }
}

int oura_cva(const char *model_path, const float *ppg, int n_segs, const float *demo,
             double *out_vascular_age, double *out_pwv) {
    if (!model_path || !ppg || !demo || !out_vascular_age || !out_pwv || n_segs <= 0) return -1;
    std::lock_guard<std::mutex> lock(g_torch);
    try {
        auto &m = cachedModule(model_path, g_cva.module, g_cva.path);
        auto ppg_t = blobFloat2d(ppg, n_segs, 1500);
        auto demo_t = blobFloat2d(demo, 1, 5);
        auto out = m.forward({ppg_t, demo_t}).toTuple();
        // (daily_cva, quality, raw_quality, daily_pwv, ppg_segment_metrics)
        *out_vascular_age = out->elements()[0].toTensor().item<double>();
        *out_pwv = out->elements()[3].toTensor().item<double>();
        return 0;
    } catch (const std::exception &e) {
        NSLog(@"oura_cva: %s", e.what());
        return -1;
    }
}

static at::Tensor mat(const float *p, int rows, int cols) {
    return rows > 0 ? blobFloat2d(p, rows, cols) : at::empty({0, cols}, at::kFloat);
}

// Swift copies this immediately after a failed synchronous call. Thread-local
// storage avoids another queued model run overwriting the diagnostic.
static thread_local std::string activity_error;
const char *oura_activity_last_error(void) { return activity_error.c_str(); }
static int activityFailure(const std::string &message) {
    activity_error = message;
    NSLog(@"%s", message.c_str());
    return -1;
}

int oura_activity(const char *model_path, const float *context, const float *user,
                  const float *met, int n_met, const float *step, int n_step,
                  const float *motion, int n_motion,
                  const float *temp, int n_temp, const float *hr, int n_hr,
                  float threshold, float min_duration, float *out_workouts, int max_rows) {
    activity_error.clear();
    if (!model_path || !context || !user || !out_workouts || max_rows <= 0)
        return activityFailure("activity: invalid model inputs or output buffer");
    std::lock_guard<std::mutex> lock(g_torch);
    try {
        // ActivityModel calls once per retained local day. Loading the 15 MB module
        // for every day dominated sync time, so keep it until oura_torch_release().
        auto &m = cachedModule(model_path, g_activity.module, g_activity.path);
        auto context_t = at::from_blob((void *)context, {4}, at::kFloat).clone();
        auto user_t = at::from_blob((void *)user, {14}, at::kFloat).clone();
        auto met_t = mat(met, n_met, 2);
        auto motion_t = mat(motion, n_motion, 9);
        auto temp_t = mat(temp, n_temp, 2);
        auto hr_t = mat(hr, n_hr, 2);

        auto step_t = mat(step, n_step, 12);

        // One row of detection settings: probability threshold, minimum duration and
        // tuning values; NaN selects the model default.
        const float nanf = std::numeric_limits<float>::quiet_NaN();
        const float settings[7] = {threshold, nanf, min_duration, 0.f, nanf, nanf, nanf};
        auto settings_t = at::from_blob((void *)settings, {1, 7}, at::kFloat).clone();
        std::vector<c10::IValue> inputs{context_t, user_t, met_t, step_t, motion_t, temp_t, hr_t,
                                        c10::IValue(), c10::IValue(), settings_t};
        auto out = m.forward(inputs).toTuple();
        auto workouts = out->elements()[0].toTensor().to(at::kFloat).contiguous();
        if (!workouts.defined() || workouts.numel() == 0) return 0;
        if (workouts.dim() != 2 || workouts.size(1) != 9) {
            return activityFailure("activity: expected a workouts tensor with 9 columns, got rank " + std::to_string(workouts.dim()));
        }
        int n = std::min<int>((int)workouts.size(0), max_rows);
        const float *wp = workouts.data_ptr<float>();
        for (int i = 0; i < n * 9; i++) out_workouts[i] = wp[i];
        if ((int)workouts.size(0) > max_rows) {
            NSLog(@"oura_activity: truncated %d sessions to %d", (int)workouts.size(0), max_rows);
        }
        return n;
    } catch (const std::exception &e) {
        return activityFailure(std::string("activity: ") + e.what());
    }
}

int oura_illness(const char *model_path, const float *series, const float *scalars,
                 double *out_score, int *out_decision, float *out_biomarkers) {
    if (!model_path || !series || !scalars || !out_score || !out_decision || !out_biomarkers) return -1;
    std::lock_guard<std::mutex> lock(g_torch);
    try {
        auto &m = cachedModule(model_path, g_illness.module, g_illness.path);
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
            if (v.numel() < 4) {
                NSLog(@"oura_illness: biomarker %d too short (%d)", b, (int)v.numel());
                return -1;
            }
            const float *vp = v.data_ptr<float>();
            for (int j = 0; j < 4; j++) out_biomarkers[b * 4 + j] = vp[j]; // [is_out,value,min,max]
        }
        return 0;
    } catch (const std::exception &e) {
        NSLog(@"oura_illness: %s", e.what());
        return -1;
    }
}
