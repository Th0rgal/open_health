// Validation-only bridge: type-check Swift model plumbing without proprietary weights.
// Never included by project.yml or project-ci.yml; no inference is performed here.
#include "../apps/ios/OuraApp/TorchBridge.h"
int oura_sleepnet(const char *path, const int64_t *it, const float *iv, int ni,
                  const int64_t *at, const float *av, int na,
                  const int64_t *tt, const float *tv, int nt,
                  int64_t start, int64_t end, int *stages, int64_t *timestamps, int cap) { return -1; }
int oura_cva(const char *path, const float *ppg, int n, const float *demo,
             double *age, double *pwv) { return -1; }
const char *oura_activity_last_error(void) { return "validation stub: inference unavailable"; }
int oura_activity(const char *path, const float *context, const float *user,
                  const float *met, int nm, const float *step, int ns,
                  const float *motion, int no, const float *temp, int nt,
                  const float *hr, int nh, float threshold, float duration,
                  float *out, int cap) { return -1; }
int oura_stepmotion(const char *path, const int64_t *ts, const float *raw,
                    int n, int64_t *out_ts, float *out, int cap) { return -1; }
int oura_illness(const char *path, const float *series, const float *scalars,
                 double *score, int *decision, float *biomarkers) { return -1; }
