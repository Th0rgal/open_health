/*
 * Capture the AES-256-GCM key(s) the Oura app uses to decrypt its on-device models.
 *
 * docs/algorithms/sleepnet.md reverse-engineered the format:
 *   plaintext = AES/GCM/NoPadding decrypt(ciphertext, key, GCMParameterSpec(128, iv))
 * with the key SERVER-DELIVERED and cached (Keystore-wrapped) on a logged-in device —
 * so it cannot be recovered from the APK, but the app holds it in memory to load models.
 *
 * This hooks javax.crypto.Cipher.init and reports every distinct 32-byte AES key used for
 * a DECRYPT, class-name-independently. One model load is enough to surface it; the key is
 * per-label (A/B rotation), not per-model, so one or two keys decrypt everything. With the
 * key, capture_model_key.py decrypts all assets/*.pt.enc offline — no per-screen racing.
 *
 * The key is emitted only over the frida message channel to the driver, which writes it to
 * a 0600 file. Necessary exposure: the key IS the artifact here.
 */
'use strict';
Java.perform(function () {
  var Cipher = Java.use('javax.crypto.Cipher');
  var GCMSpec = Java.use('javax.crypto.spec.GCMParameterSpec');
  var seen = {};

  function hex(bytes) {
    var s = '';
    for (var i = 0; i < bytes.length; i++) s += ('0' + (bytes[i] & 0xff).toString(16)).slice(-2);
    return s;
  }

  // init(opmode, key, params) — the overload that carries the GCM IV.
  Cipher.init.overload('int', 'java.security.Key', 'java.security.spec.AlgorithmParameterSpec')
    .implementation = function (opmode, key, params) {
      try {
        // 2 == DECRYPT_MODE
        if (opmode === 2 && key !== null) {
          var alg = key.getAlgorithm ? key.getAlgorithm() : '';
          var enc = key.getEncoded ? key.getEncoded() : null;
          if (enc && enc.length === 32 && ('' + alg).toUpperCase().indexOf('AES') >= 0) {
            var kh = hex(enc);
            if (!seen[kh]) {
              seen[kh] = true;
              send({ t: 'key', key: kh, alg: '' + alg });
            }
          }
        }
      } catch (e) { send({ t: 'err', e: '' + e }); }
      return this.init(opmode, key, params);
    };

  send({ t: 'ready' });
});
