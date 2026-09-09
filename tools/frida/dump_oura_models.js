/*
 * Dump Oura's decrypted on-device PyTorch models by hooking the app's OWN decryption
 * at runtime. The models ship as assets/<name>.pt.enc in split_oura_models.apk, encrypted
 * AES-256-GCM with a SERVER-DELIVERED key that is only cached (Keystore-wrapped) on a
 * logged-in device — see docs/algorithms/sleepnet.md. So they cannot be decrypted offline
 * from the APK, but the app itself decrypts them on demand, and this rides along.
 *
 * Rather than chase Oura's class names (which move between app versions), this hooks
 * javax.crypto.Cipher.doFinal and keeps any plaintext that is a TorchScript container —
 * a Zip (`PK\x03\x04`) or the legacy pickle magic. That is version-independent.
 *
 * Files are written on the DEVICE to /data/local/tmp/oura_models_dump/<sha256>.pt; the
 * driver (dump_oura_models.py) names them by matching size+hash against the .enc assets
 * and pulls them off. Frida is loud on stdout but never prints key material.
 *
 * Usage (via the driver): python tools/frida/dump_oura_models.py
 */
'use strict';

var OUT_DIR = '/data/local/tmp/oura_models_dump';

function isTorchScript(bytes) {
  if (!bytes || bytes.length < 8) return false;
  // Zip local file header "PK\x03\x04" — modern TorchScript / .ptl containers.
  if (bytes[0] === 0x50 && bytes[1] === 0x4b && bytes[2] === 0x03 && bytes[3] === 0x04) return true;
  // Legacy torch pickle: 0x80 0x02 (pickle proto 2) then 0x8a or '(' — be permissive.
  if (bytes[0] === 0x80 && (bytes[1] === 0x02 || bytes[1] === 0x03)) return true;
  return false;
}

Java.perform(function () {
  var Cipher = Java.use('javax.crypto.Cipher');
  var File = Java.use('java.io.File');
  var FOS = Java.use('java.io.FileOutputStream');
  var MessageDigest = Java.use('java.security.MessageDigest');

  try { File.$new(OUT_DIR).mkdirs(); } catch (e) {}

  var seen = {};
  var count = 0;

  function persist(bytes) {
    var md = MessageDigest.getInstance('SHA-256');
    var digest = md.digest(bytes);
    var hex = '';
    for (var i = 0; i < digest.length; i++) {
      hex += ('0' + (digest[i] & 0xff).toString(16)).slice(-2);
    }
    if (seen[hex]) return;
    seen[hex] = true;
    var path = OUT_DIR + '/' + hex + '.pt';
    var fos = FOS.$new(path);
    fos.write(bytes);
    fos.close();
    count++;
    console.log('[dump] wrote ' + bytes.length + ' bytes -> ' + hex + '.pt  (total ' + count + ')');
  }

  // Two doFinal overloads produce a fresh byte[]; those are the ones that hand back the
  // whole decrypted model. The into-buffer variants are used for streaming and ignored.
  ['doFinal', 'doFinal'].forEach(function () {});

  Cipher.doFinal.overload('[B').implementation = function (input) {
    var out = this.doFinal(input);
    try { if (isTorchScript(out)) persist(out); } catch (e) { console.log('[dump] err ' + e); }
    return out;
  };

  Cipher.doFinal.overload('[B', 'int', 'int').implementation = function (input, off, len) {
    var out = this.doFinal(input, off, len);
    try { if (isTorchScript(out)) persist(out); } catch (e) { console.log('[dump] err ' + e); }
    return out;
  };

  Cipher.doFinal.overload().implementation = function () {
    var out = this.doFinal();
    try { if (isTorchScript(out)) persist(out); } catch (e) { console.log('[dump] err ' + e); }
    return out;
  };

  // The docs describe PytorchModelFactory.createTemporaryFile: decrypt -> temp file ->
  // torch load -> delete. Catch that path too, class-name-independently, by copying any
  // temp file that is a TorchScript zip the instant before the app deletes it. This is
  // the backstop for a decrypt that streams (so Cipher.doFinal never sees whole bytes).
  var FIS = Java.use('java.io.FileInputStream');
  function persistFile(f) {
    try {
      if (!f.exists() || f.length() < 64) return;
      var head = Java.array('byte', [0, 0, 0, 0]);
      var fis = FIS.$new(f);
      fis.read(head); fis.close();
      if (!isTorchScript(head)) return;
      var all = Java.use('java.nio.file.Files').readAllBytes(f.toPath());
      persist(all);
    } catch (e) {}
  }
  File.delete.implementation = function () {
    try { persistFile(this); } catch (e) {}
    return this.delete();
  };

  console.log('[dump] hooks installed (Cipher.doFinal + temp-file preserve) — open Sleep/Activity');
});
