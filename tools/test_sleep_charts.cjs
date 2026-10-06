// Run without a browser; exercise the actual chart functions from the web client.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const source = fs.readFileSync('dashboard/web/app.js', 'utf8');
const smooth = source.slice(source.indexOf('function smoothPath('), source.indexOf('// monochrome, thin'));
const stage = source.slice(source.indexOf('const STAGE ='), source.indexOf('const parseHM ='));
const hypno = source.slice(source.indexOf('function hypnoSvg('), source.indexOf('// smooth auto-scaled line'));
const lane = source.slice(source.indexOf('function laneSvg('), source.indexOf('// horizontal stage-proportion bar'));
const context = vm.createContext({});
vm.runInContext(smooth + stage + hypno + lane, context);
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

// A first HR/HRV sample 47.23 minutes after bedtime must not be placed at bedtime (x=0),
// and long missing intervals (>15m) must break the line instead of stretching across the gap.
const startUnix = 1791068400; // Oct 4 bedtime
const endUnix = startUnix + 8 * 3600; // 8h night
const firstOffsetS = Math.round(47.23 * 60 * 10) / 10; // 2833.8 s
const axis = { frac: (t) => (t - startUnix) / (endUnix - startUnix) };
const timedPts = [
  [startUnix + firstOffsetS, 58],
  [startUnix + firstOffsetS + 300, 56],
  // 45-minute missing gap (> LANE_GAP_S = 900s)
  [startUnix + firstOffsetS + 300 + 2700, 52],
  [startUnix + firstOffsetS + 600 + 2700, 54],
];
const timedLane = context.timedLaneSvg(timedPts, axis, 1000, 50, 'red');
assert(timedLane);
const expectedFirstX = ((firstOffsetS / (endUnix - startUnix)) * 1000).toFixed(1);
assert(timedLane.svg.includes(`M${expectedFirstX} `), `expected first point at M${expectedFirstX}, not M0.0`);
assert(!timedLane.svg.includes('M0.0 '), 'sample 47.23 min after bedtime must not start at bedtime x=0');
// Two segments separated by >15m gap produce two M commands in the stroke path.
const strokeMatch = timedLane.svg.match(/<path d="([^"]+)" fill="none"/);
assert(strokeMatch);
const moveCommands = strokeMatch[1].trim().split(/\s+/).filter((tok) => tok.startsWith('M'));
assert.equal(moveCommands.length, 2, 'gap > 15m must split the polyline into 2 separate segments');
// Scrubbing at bedtime or inside the 45-minute gap returns null (rendered as "—").
const laneTolS = (15 * 60) / 2;
assert.equal(context.nearestPoint(timedPts, startUnix, laneTolS), null);
assert.equal(context.nearestPoint(timedPts, startUnix + firstOffsetS + 300 + 1350, laneTolS), null);
assert.deepEqual(context.nearestPoint(timedPts, startUnix + firstOffsetS + 60, laneTolS), timedPts[0]);

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
