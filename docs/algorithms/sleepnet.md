# SleepNet (sleep staging model)

The sleep **hypnogram** (per-30s DEEP/LIGHT/REM/AWAKE) is produced on the phone by
a PyTorch model - *not* by ecore (which only computes staging features and
everything downstream of the stage array). The models ship encrypted in the APK:

- `oura_models.apk/assets/sleepstaging_2_6_0.pt.enc` (114 KB - the stager)
- `sleepnet_moonstone_1_2_0.pt.enc`, `sleepnet_bdi_0_3_0/0_4_0.pt.enc` (apnea / SpO2 / BDI)

## Decryption - fully reverse-engineered

`com/ouraring/pytorch/PytorchModelFactory.java` (`createTemporaryFile$lambda$0$0`):

```
key = EncryptionKeyHandler.getKey(getCurrentKeyLabel())   // 32-byte AES-256 key
iv  = first 12 bytes of the .pt.enc file
ct  = remaining bytes (AES-GCM ciphertext + 128-bit tag)
plaintext = AES/GCM/NoPadding decrypt(ct, key, GCMParameterSpec(128, iv))
```

So the format is **`[12-byte IV][AES-256-GCM ciphertext + 16-byte tag]`** - consistent
with the observed non-block-aligned `.enc` sizes.

## The blocker: the key is server-delivered

`getCurrentKey()` → `EncryptionKeyHandler.getKey(label)`. `EncryptionKeyHandler` is
an interface with `getKey`/`saveKey`/`getCurrentKeyLabel`; keys are **delivered by
the backend** and saved locally - `com/ouraring/core/model/backend/KeyDeliveryModel.java`
calls `saveKey(label, key)` with keys from the client-configuration JSON
(`model_key_a`/`model_key_b` + `label_a`/`label_b`). **The decryption key is not in
the APK.**

(A *different* key, baked into `libsecrets.so` and derived as
`apiKey[i] = obf[i] XOR sha256_hex("com.ouraring.core.utils")[i]`
→ `1h9mi6ZRsrKfHH%r5Ox!Gkig!%VeIbMt`, AES/ECB/PKCS5 - decrypts other app secrets,
not the models. Confirmed: it does not decrypt the `.pt.enc` files.)

## Conclusion

The SleepNet models **cannot be decrypted offline** from the APK alone - the GCM
key is fetched from Oura's servers (per-model, labeled, rotatable) and only cached
on a logged-in device. So the **sleep hypnogram is the one metric that is not
reproducible without Oura's cloud**, on two counts: it isn't computed in ecore, and
its model is encrypted with a server-delivered key.

Routes that would unblock it (all require a valid Oura account/session, so out of
scope for a cloud-free client):
1. Fetch the model key from the client-config endpoint with an authenticated session.
2. Extract the locally-saved key from a logged-in device's app storage, then GCM-
   decrypt with the recipe above.

## Update — route 2 implemented (`tools/frida/`)

Route 2 is now scripted for a **rooted device with the logged-in app**. The key never
appears in the APK and the app's `androidx.security` classes are obfuscated, so the key is
captured live from the app's own decryption rather than reconstructed:

- `tools/frida/capture_model_key.py` + `capture_model_key.js` attach Frida and hook
  `javax.crypto.Cipher`, correlating `init` → `doFinal` by the cipher's stable Java identity
  and reporting the AES-256 key **only** when that cipher's output is a TorchScript zip — so
  the plaintext proves the key, never a guess. The models decrypt lazily on fresh inference
  (results are persisted), so the reliable trigger is a live sync or the periodic
  daytime-stress model; a cold spawn plus normal navigation also works.
- `tools/frida/decrypt_all_models.py` then decrypts every `assets/*.pt.enc` offline with the
  captured key (the GCM tag verifies each), writing `notes/models/<name>.pt`.
- `tools/export_mobile.py` converts those to the `.ptl` the on-device clients load.

One caveat this surfaced: the key is a single AES-256-GCM key shared across all current
models (not per-model), and `sleepstaging_2_6_0` still cannot be lite-exported — it needs the
custom `oura_ops::oura_create_windows` op absent from the mobile runtime — so `sleepnet_
moonstone` remains the stager used on-device. The app has also moved `cva` from `2_1_0` to
`2_1_5` (same signature, a drop-in).

This unblocks the on-device hypnogram for a client that has a rooted phone with the official
app; it is still not reproducible from ring data alone.
3. Train an independent staging model from the raw signals we *do* decode (HR/IBI,
   HRV, temperature, motion) - a from-scratch reimplementation, not a port.
