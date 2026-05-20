#!/usr/bin/env node
// process_health_heal — the ProcessMacrophage.Heal :exec executor.
//
// [antibody-exempt: bin/process_health_heal.mjs — the program the
//  :exec adapter (framework/process_health/process_health.hecksagon,
//  resolve_exec_adapters in rust/src/runtime/mod.rs) invokes when
//  ProcessMacrophage.Heal dispatches. The ProcessHealth bluebook
//  names the contract (Heal records the dispatch + emits HealRequested) ;
//  this Node script is its impure executor (overmind detect / restart /
//  MarkAlive). Kernel-adjacent by nature : no bluebook can hold a
//  shell-out to overmind. Mirrors bin/inbox_poll.mjs pattern.]
//
// Contract (process_health.bluebook v2 + process_health.hecksagon) :
//
//   1. Resolve the `overmind` binary up front. If absent, fail loud
//      to stderr and exit non-zero — the Cascade.RecordResult will
//      carry the failure back to the bus, the script never silently
//      no-ops.
//
//   2. Detect whether overmind itself is alive : `overmind ps`
//      against the .overmind.sock in hecks_conception/. If the
//      socket is missing OR ps returns non-zero, the supervisor is
//      dead — `overmind start -D` from hecks_conception/ brings
//      everything back, and the script exits (the next sweep will
//      pick the per-process state back up).
//
//   3. Otherwise read process_sentinel.heki, filter records where
//      state=dead, and for each dead sentinel run
//      `overmind restart <process_name>`. On a successful restart,
//      dispatch ProcessHealth::ProcessSentinel.MarkAlive on the
//      sentinel so the ProposeHealOnDeath policy doesn't re-fire on
//      the next sweep (state=dead → Heal → MarkDead → Heal → ... is
//      the failure mode the MarkAlive flip closes).
//
//   4. Print a one-line summary to stdout. The exec_dispatcher
//      captures stdout/stderr/exit_code and cascades the outcome
//      into Cascade.RecordResult, joinable against the dispatching
//      invocation by id.
//
// cwd : the runtime process cwd (overmind process_macrophage member
// runs from hecks_conception/, so relative paths resolve identically
// whether the loop or a manual storehouse dispatch fired this).

import fs from "node:fs";
import path from "node:path";
import { spawnSync } from "node:child_process";

const HERE = path.dirname(new URL(import.meta.url).pathname);
const HECKS_CONCEPTION = path.resolve(HERE, "..");
const STOREHOUSE = path.join(HECKS_CONCEPTION, "..", "rust", "target", "release", "storehouse");
const OVERMIND_SOCK = path.join(HECKS_CONCEPTION, ".overmind.sock");
const INFO_DIR = process.env.MIETTE_INFO_DIR
  || path.join(process.env.HOME, "miette-state", "information");
const SENTINEL_HEKI = path.join(INFO_DIR, "process_health", "process_sentinel.heki");

function log(...a) { console.log("[process_health_heal]", ...a); }
function errlog(...a) { process.stderr.write("[process_health_heal] " + a.join(" ") + "\n"); }

// Resolve a binary on PATH. Returns absolute path or null.
function which(bin) {
  const PATH_DIRS = (process.env.PATH || "").split(":");
  const exts = ["", ".sh"];
  for (const d of PATH_DIRS) {
    for (const e of exts) {
      const p = path.join(d, bin + e);
      try { fs.accessSync(p, fs.constants.X_OK); return p; } catch {}
    }
  }
  return null;
}

// Run a command synchronously, capture exit + stdout + stderr.
// Never throws — returns a result object.
function run(bin, args, opts = {}) {
  const r = spawnSync(bin, args, { encoding: "utf8", ...opts });
  return {
    ok: r.status === 0,
    exitCode: r.status === null ? -1 : r.status,
    stdout: r.stdout || "",
    stderr: r.stderr || "",
    error: r.error ? r.error.message : null,
  };
}

// Read process_sentinel.heki via `storehouse heki list ... --where state=dead`.
// Returns an array of process_name strings (the sentinel ids).
function deadSentinels() {
  if (!fs.existsSync(SENTINEL_HEKI)) return [];
  const r = run(STOREHOUSE, ["heki", "list", SENTINEL_HEKI,
                             "--where", "state=dead",
                             "--fields", "process_name",
                             "--format", "tsv"]);
  if (!r.ok) {
    errlog("heki list failed:", r.stderr.trim() || r.error || `exit=${r.exitCode}`);
    return [];
  }
  return r.stdout.split("\n").map(s => s.trim()).filter(s => s.length > 0);
}

// After a successful overmind restart, dispatch MarkAlive on the
// sentinel so the ProposeHealOnDeath policy doesn't loop on the next
// sweep. signal_source=heartbeat means "we believe restart worked ;
// the next sweep will confirm via real heartbeat" — if the restart
// didn't actually bring the process back, the sweep's pgrep/log_mtime
// signal will flip it back to hanged/dead and a fresh Heal will fire.
function dispatchMarkAlive(processName) {
  const now = new Date().toISOString();
  // Universal door : `storehouse <aggregates_root> <FQN.Command> k=v ...`
  // (the positional-FQN route in rust/src/main.rs that
  // looks_like_aggregate_command + dispatch_hecksagon serves).
  const r = run(STOREHOUSE, [
    path.join(HECKS_CONCEPTION, "aggregates"),
    "ProcessHealth::ProcessSentinel.MarkAlive",
    `process_name=${processName}`,
    `last_seen_at=${now}`,
    `signal_source=heartbeat`,
  ]);
  if (!r.ok) {
    errlog(`MarkAlive dispatch failed for ${processName}:`,
           r.stderr.trim() || r.error || `exit=${r.exitCode}`);
  }
  return r.ok;
}

function main() {
  // 1. Resolve overmind. Fail loud if missing.
  const overmind = which("overmind");
  if (!overmind) {
    errlog("FATAL : `overmind` not found on PATH. Heal cannot act.");
    errlog("PATH was :", process.env.PATH || "(empty)");
    process.exit(2);
  }
  log("overmind resolved at", overmind);

  // 2. Detect supervisor liveness via the socket.
  const socketAlive = fs.existsSync(OVERMIND_SOCK);
  let supervisorAlive = false;
  if (socketAlive) {
    const ps = run(overmind, ["ps"], { cwd: HECKS_CONCEPTION });
    supervisorAlive = ps.ok;
  }

  if (!supervisorAlive) {
    log("overmind supervisor appears dead (socket present:", socketAlive,
        ") — running `overmind start -D`");
    const start = run(overmind, ["start", "-D"], { cwd: HECKS_CONCEPTION });
    if (!start.ok) {
      errlog("overmind start -D failed:",
             start.stderr.trim() || start.error || `exit=${start.exitCode}`);
      process.exit(start.exitCode || 1);
    }
    log("overmind start -D ok — supervisor relaunched. Per-process Heal will pick up next sweep.");
    process.exit(0);
  }

  // 3. Walk dead sentinels and restart each.
  const dead = deadSentinels();
  if (dead.length === 0) {
    log("no dead sentinels — nothing to heal. (Heal may have been triggered by ProposeHealOnDeath ahead of the heki record landing.)");
    process.exit(0);
  }

  log(`dead sentinels (${dead.length}) :`, dead.join(", "));
  let healed = 0;
  let failed = 0;
  for (const name of dead) {
    log(`overmind restart ${name}`);
    const r = run(overmind, ["restart", name], { cwd: HECKS_CONCEPTION });
    if (!r.ok) {
      errlog(`restart ${name} failed:`,
             r.stderr.trim() || r.error || `exit=${r.exitCode}`);
      failed++;
      continue;
    }
    // 4. MarkAlive so the policy doesn't re-fire.
    if (dispatchMarkAlive(name)) {
      healed++;
      log(`restart ${name} ok ; MarkAlive dispatched`);
    } else {
      failed++;
    }
  }

  log(`done : ${healed} healed, ${failed} failed`);
  if (failed > 0) process.exit(1);
}

try { main(); }
catch (e) { errlog("FATAL", e.message); process.exit(1); }
