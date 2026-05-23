#!/usr/bin/env node
// sidequest_run.mjs — the spawn leaf for Tools::Sidequest (i707).
//
// Fired by the RunSidequestOnDispatch policy via Primitive::Process.Spawn
// (cmd "node bin/sidequest_run.mjs", result_into Cascade.RecordResult).
// This is the analogue of bin/process_health_heal.mjs : the bluebook stays
// pure (records the dispatch + emits SidequestDispatched) ; this impure leaf
// reads the latest dispatched Sidequest record from the heki, runs the agent
// headless (`claude -p <prompt>`), and prints the transcript so
// Cascade.RecordResult carries it back to the bus.
//
// Idempotency : the policy fires on EVERY SidequestDispatched, so the leaf
// claims each sidequest id exactly once via a /tmp marker. A second fire for
// the same id is a no-op — the policy can never re-spawn an old dispatch or
// loop. Always exits 0 (fail-safe) so a spawn failure never errors the cascade.

import { spawnSync, execFileSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";

const STOREHOUSE = process.env.STOREHOUSE_BIN || "storehouse";
const HOME = os.homedir();
const log = (m) => console.log(`[sidequest_run] ${m}`);

// Dispatches against hecks_conception persist heki under miette-state/.
const candidates = [
  `${HOME}/Projects/miette-state/information/sidequest/sidequest.heki`,
  `${HOME}/Projects/hecks/hecks_conception/information/sidequest/sidequest.heki`,
];
const hekiPath = candidates.find((p) => fs.existsSync(p));
if (!hekiPath) { log("no sidequest heki found; nothing to run"); process.exit(0); }

// Latest record via the storehouse CLI (JSON).
let rec;
try {
  rec = JSON.parse(execFileSync(STOREHOUSE, ["heki", "latest", hekiPath], { encoding: "utf8" }));
} catch (e) { log(`could not read latest sidequest: ${e.message}`); process.exit(0); }

// VO fields may be flat or {value:…}; tolerate both.
const unwrap = (v) => (v && typeof v === "object" && "value" in v ? v.value : v);
const id = unwrap(rec.id);
const prompt = unwrap(rec.prompt);
if (!id || !prompt) { log("latest record has no id/prompt; skipping"); process.exit(0); }

// Idempotent claim — one spawn per id, ever.
const marker = `${os.tmpdir()}/sidequest_claimed_${id}`;
if (fs.existsSync(marker)) { log(`${id} already claimed; skipping`); process.exit(0); }
fs.writeFileSync(marker, new Date().toISOString());

log(`spawning agent for sidequest ${id}`);
const res = spawnSync("claude", ["-p", prompt, "--dangerously-skip-permissions"], {
  encoding: "utf8",
  maxBuffer: 64 * 1024 * 1024,
});
if (res.error) { log(`claude spawn failed: ${res.error.message}`); process.exit(0); }
log(`sidequest ${id} transcript:\n${res.stdout || "(no stdout)"}`);
if (res.stderr) log(`stderr:\n${res.stderr}`);
process.exit(0);
