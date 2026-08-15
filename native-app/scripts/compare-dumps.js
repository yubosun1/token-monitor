#!/usr/bin/env node
// Compare two Token Monitor stats fixture dumps (PLAN.md Phase 0):
//   node compare-dumps.js <before.json> <after.json> [more.json...]
//
// Volatile keys (timestamps, day-dependent windows) are normalized before
// the deep comparison so runs from the same session but different seconds
// compare cleanly. Exits non-zero when any structural difference remains.
"use strict";

const files = process.argv.slice(2);
if (files.length < 2) {
  console.error("usage: compare-dumps.js <before.json> <after.json> [more...]");
  process.exit(2);
}

const VOLATILE_KEYS = new Set(["updatedAt", "receivedAt", "periodWindows", "ageMs", "stale"]);

function normalize(node) {
  if (Array.isArray(node)) return node.map(normalize);
  if (node && typeof node === "object") {
    const out = {};
    for (const [k, v] of Object.entries(node)) {
      if (VOLATILE_KEYS.has(k)) continue;
      out[k] = normalize(v);
    }
    return out;
  }
  return node;
}

function load(path) {
  return normalize(JSON.parse(require("fs").readFileSync(path, "utf8")));
}

function diffs(a, b, path, out) {
  if (Array.isArray(a) && Array.isArray(b)) {
    if (a.length !== b.length) {
      out.push(path + "[] length " + a.length + " != " + b.length);
      return;
    }
    for (let i = 0; i < a.length; i++) diffs(a[i], b[i], path + "[" + i + "]", out);
    return;
  }
  if (a && b && typeof a === "object" && typeof b === "object") {
    const keys = new Set([...Object.keys(a), ...Object.keys(b)]);
    for (const k of keys) {
      if (!(k in a)) out.push(path + "." + k + " only in after");
      else if (!(k in b)) out.push(path + "." + k + " only in before");
      else diffs(a[k], b[k], path + "." + k, out);
    }
    return;
  }
  // Tolerate 1e-9 relative float jitter; report larger numeric deltas.
  if (typeof a === "number" && typeof b === "number") {
    if (Math.abs(a - b) > 1e-6 * Math.max(1, Math.abs(a), Math.abs(b))) {
      out.push(path + " " + a + " != " + b);
    }
    return;
  }
  if (a !== b) out.push(path + " " + JSON.stringify(a) + " != " + JSON.stringify(b));
}

const baseline = load(files[0]);
let failures = 0;
for (const f of files.slice(1)) {
  const out = [];
  diffs(baseline, load(f), "$", out);
  if (out.length) {
    failures++;
    console.log(f + " differs from " + files[0] + ":");
    for (const d of out.slice(0, 40)) console.log("  " + d);
    if (out.length > 40) console.log("  ... " + (out.length - 40) + " more");
  } else {
    console.log(f + " matches " + files[0]);
  }
}
process.exit(failures ? 1 : 0);

