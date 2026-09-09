#!/usr/bin/env node
/*
 * Extract an Oura Android DbRingConfiguration auth_key from assa-store.realm.
 *
 * Requires the npm `realm` package:
 *   npm install realm@20
 *
 * The key is written to a 0600 file and is never printed.
 */

const fs = require("fs");
let Realm;
try {
  Realm = require("realm");
} catch {
  Realm = require(require.resolve("realm", { paths: [process.cwd()] }));
}

function usage() {
  console.error(
    "usage: extract_oura_realm_key.js <assa-store.realm> <out-key-file> [serial-or-mac]\n" +
      "\n" +
      "The selector is optional. Without it the active ring configuration is used, and\n" +
      "an error lists the available rings if more than one qualifies. Not every ring's\n" +
      "serial matches the 50xxxBxxxxxxxxxx shape the byte-scanner looks for, so the MAC\n" +
      "address (which the app logs as `macAddress:`) is accepted too."
  );
  process.exit(2);
}

const [realmPath, outPath, selector] = process.argv.slice(2);
if (!realmPath || !outPath) usage();

const norm = (value) =>
  String(value ?? "").replace(/[:\s-]/g, "").toUpperCase();

const realm = new Realm.Realm({ path: realmPath, readOnly: true });
try {
  const rows = Array.from(realm.objects("DbRingConfiguration"));
  if (rows.length === 0) {
    throw new Error("no DbRingConfiguration rows — has the ring finished onboarding?");
  }

  const describe = (row) =>
    `serial=${row.serial_number || "?"} mac=${row.mac_address || "?"} ` +
    `active=${row.in_active_use === true} deleted=${row.deleted_at != null}`;

  // The selector matches either the serial or the MAC, punctuation-insensitively.
  const matching = selector
    ? rows.filter(
        (row) =>
          norm(row.serial_number) === norm(selector) ||
          norm(row.mac_address) === norm(selector)
      )
    : rows;
  if (matching.length === 0) {
    throw new Error(
      `no DbRingConfiguration row matching ${selector}. Available:\n  ` +
        rows.map(describe).join("\n  ")
    );
  }

  const live = matching.filter((row) => row.deleted_at == null);
  const active =
    live.find((row) => row.in_active_use === true) || live[0] || matching[0];

  // Only guess when the choice is unambiguous; a wrong key silently fails to auth.
  const contenders = live.filter((row) => row.in_active_use === true);
  if (!selector && contenders.length > 1) {
    throw new Error(
      `several rings are in active use — pass a serial or MAC:\n  ` +
        contenders.map(describe).join("\n  ")
    );
  }

  if (!active.auth_key || active.auth_key.byteLength !== 16) {
    throw new Error(`DbRingConfiguration.auth_key is missing or not 16 bytes`);
  }

  const hex = Buffer.from(active.auth_key).toString("hex");
  fs.writeFileSync(outPath, `${hex}\n`, { mode: 0o600 });
  fs.chmodSync(outPath, 0o600);

  console.log(
    JSON.stringify({
      wrote: outPath,
      serial: active.serial_number,
      mac_address: active.mac_address,
      android_ble_identifier: active.android_ble_identifier,
      auth_key_bytes: active.auth_key.byteLength,
    })
  );
} finally {
  realm.close();
}

process.exit(0);
