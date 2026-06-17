#!/usr/bin/env node
// artifact_claim_scan — the NoPromisesSweep.Scan Process.Spawn leaf.
//
// Contract (artifact_claim.bluebook) : walk scan_root for .bluebook
// source, extract artifact-path tokens a bluebook claims to exist,
// dispatch Discipline::ArtifactClaim.RecordClaim (upsert) per token, and
// Retract claims a source no longer makes (the stale-claim sweep). The
// verdict (satisfied/broken) is the verify leaf's job ; scan only keeps
// the claim REGISTRY in sync with what the source pages currently say.
//
// Extraction is deliberately NARROW (warn-first, grow later) : only
// tokens that strongly look like a concrete repo artifact — bin/ scripts,
// ~/.claude/ hooks, and dir-prefixed source files (rust/ ruby/ lib/
// docs/) with an extension. Free-text prose paths that don't match these
// shapes are intentionally NOT claimed yet.
//
// cwd : runtime process cwd (hecks_conception/), same as the verify leaf.

import fs from "node:fs";
import path from "node:path";
import { spawnSync } from "node:child_process";

const HERE = path.dirname(new URL(import.meta.url).pathname);
const HECKS_CONCEPTION = path.resolve(HERE, "..");
const REPO_ROOT = path.resolve(HECKS_CONCEPTION, "..");
const STOREHOUSE = path.join(REPO_ROOT, "rust", "target", "release", "storehouse");
const SCAN_ROOT = path.join(HECKS_CONCEPTION, process.env.ARTIFACT_SCAN_ROOT || "aggregates");

function log(...a) { console.log("[artifact_claim_scan]", ...a); }
function nowIso() { return new Date().toISOString().replace(/\.\d+Z$/, "Z"); }

// The narrow artifact-path matchers. Each token is trimmed of trailing
// punctuation/quotes and capped in length to avoid runaway prose grabs.
const MATCHERS = [
  { kind: "bin",    re: /\bbin\/[A-Za-z0-9._-][A-Za-z0-9._/-]*/g },
  { kind: "hook",   re: /~\/\.claude\/[A-Za-z0-9._/-]+/g },
  { kind: "source", re: /\b(?:rust|ruby|lib|docs)\/[A-Za-z0-9._/-]+\.[A-Za-z0-9]{1,5}\b/g },
];

function cleanToken(t) {
  return t.replace(/[)\]"'`.,;:]+$/, "").trim();
}

function extract(content) {
  const found = new Map(); // token -> kind
  // Skip pure-comment lines (`#...`) : doc comments carry ILLUSTRATIVE
  // path mentions (`e.g. bin/foo`, a historical ghost being explained)
  // that are not claims the bluebook actually relies on. A genuine
  // artifact claim lives in a declaration line (vision string, policy
  // cmd, attribute) — not in prose ABOUT paths. This is the narrow-v1
  // rule ; it cuts the bulk of false positives. (A claim deliberately
  // quoted inside a vision string can still slip through — reword the
  // vision rather than embed a literal example path.)
  for (const line of content.split("\n")) {
    if (/^\s*#/.test(line)) continue;
    for (const { kind, re } of MATCHERS) {
      for (const m of line.matchAll(re)) {
        const tok = cleanToken(m[0]);
        if (tok.length >= 4 && tok.length <= 120 && !found.has(tok)) found.set(tok, kind);
      }
    }
  }
  return found;
}

function walkBluebooks(dir, acc) {
  for (const ent of fs.readdirSync(dir, { withFileTypes: true })) {
    const full = path.join(dir, ent.name);
    if (ent.isDirectory()) walkBluebooks(full, acc);
    else if (ent.isFile() && ent.name.endsWith(".bluebook")) acc.push(full);
  }
  return acc;
}

function sh(args) {
  return spawnSync(STOREHOUSE, args, { encoding: "utf8" });
}

function recordClaim(claimId, source, claimedPath, context) {
  return sh([HECKS_CONCEPTION, "Discipline::ArtifactClaim.RecordClaim",
    `claim_id=${claimId}`, `source=${source}`, `claimed_path=${claimedPath}`,
    `context=${context}`, `last_scanned_at=${nowIso()}`]).status === 0;
}

function retract(claimId) {
  return sh([HECKS_CONCEPTION, "Discipline::ArtifactClaim.Retract",
    `artifact_claim=${claimId}`]).status === 0;
}

// Claims already on record for one source (for reconciliation).
function claimsForSource(source) {
  const r = sh(["query", HECKS_CONCEPTION, "Discipline::ArtifactClaim.for_source",
    `source=${source}`, "--json"]);
  if (r.status !== 0) return [];
  let parsed; try { parsed = JSON.parse((r.stdout || "").trim()); } catch { return []; }
  const state = parsed && parsed.state;
  if (!state) return [];
  return (Array.isArray(state) ? state : [state]).filter((c) => c && c.claim_id);
}

function main() {
  if (!fs.existsSync(SCAN_ROOT)) { log("scan_root missing:", SCAN_ROOT); return; }
  const files = walkBluebooks(SCAN_ROOT, []);
  let recorded = 0, retracted = 0, sources = 0;
  for (const file of files) {
    const source = path.relative(HECKS_CONCEPTION, file);
    const tokens = extract(fs.readFileSync(file, "utf8"));
    if (tokens.size === 0) continue;
    sources++;
    const currentPaths = new Set(tokens.keys());
    for (const [tok, kind] of tokens) {
      if (recordClaim(`${source}::${tok}`, source, tok, kind)) recorded++;
    }
    // Reconcile : retract claims this source no longer makes.
    for (const existing of claimsForSource(source)) {
      if (!currentPaths.has(existing.claimed_path) && existing.verdict !== "retracted") {
        if (retract(existing.claim_id)) retracted++;
      }
    }
  }
  log(`scanned ${files.length} bluebooks, ${sources} with claims : ${recorded} recorded, ${retracted} retracted`);
}

main();
