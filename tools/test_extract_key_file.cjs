// The auth key must never be written into a file that other users can read, even for an instant.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const vm = require('node:vm');

const source = fs.readFileSync('tools/extract_oura_realm_key.js', 'utf8');
const start = source.indexOf('function writeKeyFile(');
assert.notEqual(start, -1, 'writeKeyFile not found');
const fn = source.slice(start, source.indexOf('\n}\n', start) + 2);

const modesAtWrite = [];
const spyFs = {
  ...fs,
  writeFileSync(p, data, opts) {
    modesAtWrite.push(fs.statSync(p).mode & 0o777);
    return fs.writeFileSync(p, data, opts);
  },
  writeSync(fd, data) {
    modesAtWrite.push(fs.fstatSync(fd).mode & 0o777);
    return fs.writeSync(fd, data);
  },
};
const context = vm.createContext({ fs: spyFs });
vm.runInContext(fn, context);

const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'keyfile-'));
const out = path.join(dir, 'ring.key');
fs.writeFileSync(out, 'old\n', { mode: 0o644 });
fs.chmodSync(out, 0o644);

context.writeKeyFile(out, '00112233445566778899aabbccddeeff');

assert.ok(modesAtWrite.length > 0, 'no write observed');
assert.deepEqual(modesAtWrite, modesAtWrite.map(() => 0o600), `key written while mode was ${modesAtWrite.map((m) => m.toString(8))}`);
assert.equal(fs.statSync(out).mode & 0o777, 0o600);
assert.equal(fs.readFileSync(out, 'utf8'), '00112233445566778899aabbccddeeff\n');
fs.rmSync(dir, { recursive: true });
console.log('extract key file tests passed');
