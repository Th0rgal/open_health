// Run without a browser; exercise the actual chart functions from the web client.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const source = fs.readFileSync('dashboard/web/app.js', 'utf8');
const stage = source.slice(source.indexOf('const STAGE ='), source.indexOf('const parseHM ='));
const hypno = source.slice(source.indexOf('function hypnoSvg('), source.indexOf('// smooth auto-scaled line'));
const lane = source.slice(source.indexOf('function laneSvg('), source.indexOf('// horizontal stage-proportion bar'));
const context = vm.createContext({});
vm.runInContext(stage + hypno + lane, context);
const missing = context.hypnoSvg([0, 0, 0], 1000, 92);
assert(!missing.includes('class="hypno-run"'));
assert(!missing.includes('var(--wake)'));
assert(!missing.includes('var(--light)'));
assert(!context.hypnoSvg([2], 1000, 92).includes('NaN'));
assert(context.hypnoSvg([2], 1000, 92).includes('x2="1000.0"'));
const gaps = context.hypnoSvg([2, 0, 4], 1000, 92);
assert(gaps.includes('var(--light)'));
assert(gaps.includes('var(--wake)'));
// Sparse samples are bars at their true positions, never a continuous line.
const motion = context.laneSvg([3, 1, 2], 1000, 50, 'gray', [0, 1], [0.1, 0.2, 0.9]);
assert(motion.svg.includes('x1="100"'));
assert(motion.svg.includes('x1="200"'));
assert(motion.svg.includes('x1="900"'));
assert(!motion.svg.includes('<path'));
console.log('Sleep chart regression checks passed');
if (process.argv[2]) {
  const exported = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
  const night = exported.sleep.night;
  assert(night.end_unix > night.start_unix);
  assert(night.stages.every(code => [1, 2, 3, 4].includes(code)));
  assert(!context.hypnoSvg(night.stages, 1000, 92).includes('NaN'));
  const initialWake = night.stages.findIndex(code => code !== 4);
  console.log(JSON.stringify({
    app_version: exported.app_version,
    duration_minutes: (night.end_unix - night.start_unix) / 60,
    stage_cells: night.stages.length,
    encoded_initial_wake_minutes: initialWake / night.stages.length * (night.end_unix - night.start_unix) / 60,
    full_resolution_available: Array.isArray(night.stages_full),
    staging_source_available: Boolean(night.staging_source),
    motion_samples: night.series.motion.length,
    motion_timestamps_available: Array.isArray(night.series.motion_time),
    inference_replay_possible: false,
  }, null, 2));
}
