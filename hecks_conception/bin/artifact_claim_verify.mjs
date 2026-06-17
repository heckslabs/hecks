#!/usr/bin/env node
// artifact_claim_verify — the NoPromisesSweep.Verify Process.Spawn leaf.
//
// Contract (artifact_claim.bluebook) : read the Unverified work-list,
// resolve each claimed_path against the candidate bases, `test -e` it,
// and dispatch Discipline::ArtifactClaim.MarkSatisfied (exists) or
// MarkBroken (missing) back through the door per claim. stdout is a
// one-line summary the RunVerifyOnVerifyRequested policy cascades into
// Cascade.RecordResult. The bluebook holds the contract ; this is its
// impure leaf (filesystem existence is the only side effect).
//
// Path resolution : claimed paths are written relative to where the
// artifact lives — bin/ + aggregates/ resolve under hecks_conception/,
// rust/ ruby/ lib/ under the repo root, ~/ under HOME, absolute as-is.
// A claim is SATISFIED if the path exists under ANY candidate base.
//
// cwd : the runtime process cwd (hecks_conception/), same convention as
// process_health_heal / inbox_poll — relative paths resolve identically
// whether the policy spawn or a manual dispatch fired this.

import fs from "node:fs";
import path from "node:path";
import { spawnSync } from "node:child_process";

const HERE = path.dirname(new URL(import.meta.url).pathname);
const HECKS_CONCEPTION = path.resolve(HERE, "..");
const REPO_ROOT = path.resolve(HECKS_CONCEPTION, "..");
const STOREHOUSE = path.join(REPO_ROOT, "rust", "target", "release", "storehouse");
const HOME = process.env.HOME || "";

function log(...a) { console.log("[artifact_claim_verify]", ...a); }
function nowIso() { return new Date().toISOString().replace(/\.\d+Z$/, "Z"); }

// Resolve a claimed_path to the list of absolute candidates to test.
function candidates(claimed) {
  if (claimed.startsWith("~/")) return [path.join(HOME, claimed.slice(2))];
  if (path.isAbsolute(claimed)) return [claimed];
  // relative — try both roots ; bin/ + aggregates/ live in the
  // conception, rust/ ruby/ lib/ docs/ at the repo root.
  return [path.join(HECKS_CONCEPTION, claimed), path.join(REPO_ROOT, claimed)];
}

function existsAnywhere(claimed) {
  return candidates(claimed).some((c) => fs.existsSync(c));
}

// Query the Unverified work-list ; normalise single-object / array / empty.
function unverifiedClaims() {
  const r = spawnSync(STOREHOUSE,
    ["query", HECKS_CONCEPTION, "Discipline::ArtifactClaim.unverified", "--json"],
    { encoding: "utf8" });
  if (r.status !== 0) { log("query failed:", (r.stderr || "").trim()); return []; }
  let parsed;
  try { parsed = JSON.parse((r.stdout || "").trim()); }
  catch { return []; }
  const state = parsed && parsed.state;
  if (!state) return [];
  const list = Array.isArray(state) ? state : [state];
  return list.filter((c) => c && c.claim_id && c.claimed_path);
}

function mark(command, claimId) {
  const r = spawnSync(STOREHOUSE,
    [HECKS_CONCEPTION, `Discipline::ArtifactClaim.${command}`,
     `artifact_claim=${claimId}`, `last_verified_at=${nowIso()}`],
    { encoding: "utf8" });
  return r.status === 0;
}

function main() {
  const claims = unverifiedClaims();
  if (claims.length === 0) { log("no unverified claims"); return; }
  let satisfied = 0, broken = 0, failed = 0;
  for (const c of claims) {
    const ok = existsAnywhere(c.claimed_path);
    const command = ok ? "MarkSatisfied" : "MarkBroken";
    if (mark(command, c.claim_id)) {
      if (ok) satisfied++; else { broken++; log("BROKEN PROMISE:", c.source, "→", c.claimed_path); }
    } else { failed++; log("dispatch failed:", command, c.claim_id); }
  }
  log(`verified ${claims.length} : ${satisfied} satisfied, ${broken} broken, ${failed} dispatch-failed`);
}

main();
