// serve_child.mjs — long-lived `storehouse serve-stdio` child manager.
//
// The universal door (storehouse__dispatch) used to spawn a fresh
// `storehouse <root> <cmd> …` process per call, paying the ~660ms
// lazy-IR boot EVERY time. This module keeps ONE resident
// `storehouse serve-stdio <root>` child per aggregates root : the boot
// is paid once, every subsequent request is a stdin line → stdout line
// round-trip in single-digit ms.
//
// ## Protocol (must match rust/src/run_serve/mod.rs)
//
// Request : one line on the child's stdin — `Command k=v k=v …`
//           (the same positional shape the one-shot CLI takes).
// Reply   : the child writes a SENTINEL-prefixed line on stdout :
//             "\x1eRESULT " + json     — the answer
//             "\x1eERROR "  + json     — a handled dispatch error
//           Any OTHER stdout line is incidental adapter/log output and
//           is forwarded to this process's stderr, never treated as a
//           reply. The child emits one `\x1eRESULT {"ready":true}` line
//           when its boot finishes.
//
// ## Robustness (mandatory — this is the universal door)
//
// A request is serialized through a per-child queue (one in flight at a
// time) so concurrent dispatches can't interleave reads on the shared
// stdout stream. On ANY failure — spawn error, child exit, write
// error, timeout, or a `\x1eERROR` sentinel — the child is killed and
// `warmDispatch` rejects ; the caller (dispatch.mjs) falls back to a
// one-shot spawn for that request and the next request respawns a
// fresh child. A serve-child failure NEVER black-holes a dispatch.

import { spawn } from "node:child_process";

const STOREHOUSE_BIN = process.env.STOREHOUSE_BIN || "storehouse";
const RESULT_SENTINEL = "\x1eRESULT ";
const ERROR_SENTINEL = "\x1eERROR ";
// Dispatches can be slow when LLM / tool adapters fire ; generous cap.
const REQUEST_TIMEOUT_MS = Number(process.env.STOREHOUSE_SERVE_TIMEOUT_MS || 30000);
// How long to wait for the child's initial "ready" line after spawn.
const READY_TIMEOUT_MS = Number(process.env.STOREHOUSE_SERVE_READY_MS || 15000);

// One child per aggregates root. A Map keyed by absolute root path.
const children = new Map();

class ServeChild {
  constructor(aggregatesDir) {
    this.aggregatesDir = aggregatesDir;
    this.proc = null;
    this.ready = false;
    this.dead = false;
    this.buf = "";
    // Single in-flight request : { resolve, reject, timer }.
    this.pending = null;
    // Serialize requests so only one is in flight at a time.
    this.queue = Promise.resolve();
  }

  spawnIfNeeded() {
    if (this.proc && !this.dead) return;
    this.dead = false;
    this.ready = false;
    this.buf = "";
    const child = spawn(STOREHOUSE_BIN, ["serve-stdio", this.aggregatesDir], {
      env: process.env,
      stdio: ["pipe", "pipe", "pipe"],
    });
    this.proc = child;

    child.stdout.on("data", (d) => this._onStdout(d.toString()));
    child.stderr.on("data", (d) => {
      // Incidental child stderr — surface for debugging, never a reply.
      process.stderr.write(d);
    });
    const die = (why) => this._die(why);
    child.on("error", (err) => die(`spawn error: ${err && err.message ? err.message : err}`));
    child.on("close", (code) => die(`child exited (code ${code})`));
    child.on("exit", (code) => die(`child exited (code ${code})`));
  }

  _onStdout(chunk) {
    this.buf += chunk;
    let nl;
    while ((nl = this.buf.indexOf("\n")) !== -1) {
      const line = this.buf.slice(0, nl);
      this.buf = this.buf.slice(nl + 1);
      this._onLine(line);
    }
  }

  _onLine(line) {
    if (line.startsWith(RESULT_SENTINEL)) {
      const json = line.slice(RESULT_SENTINEL.length);
      // The boot-complete handshake : mark ready, don't resolve a
      // request (there is none yet).
      if (!this.ready) {
        try {
          const parsed = JSON.parse(json);
          if (parsed && parsed.ready === true) {
            this.ready = true;
            return;
          }
        } catch {
          /* fall through — treat as a reply */
        }
      }
      this._settle(json, false);
      return;
    }
    if (line.startsWith(ERROR_SENTINEL)) {
      this._settle(line.slice(ERROR_SENTINEL.length), true);
      return;
    }
    // Any other line is incidental log/adapter output from the
    // resident process — forward to stderr, never a reply.
    if (line.length) process.stderr.write(line + "\n");
  }

  _settle(json, isError) {
    const p = this.pending;
    if (!p) return; // stray line ; ignore.
    this.pending = null;
    clearTimeout(p.timer);
    if (isError) {
      // A handled dispatch error — reject so the caller falls back to
      // a clean one-shot spawn rather than returning a partial answer.
      p.reject(new Error(`serve child returned error: ${json}`));
      return;
    }
    let parsed = null;
    try {
      parsed = JSON.parse(json);
    } catch (e) {
      p.reject(new Error(`unparseable serve reply: ${e.message}`));
      this._die("unparseable reply");
      return;
    }
    p.resolve(parsed);
  }

  _die(why) {
    if (this.dead) return;
    this.dead = true;
    const p = this.pending;
    this.pending = null;
    if (this.proc) {
      try { this.proc.kill(); } catch { /* already gone */ }
    }
    this.proc = null;
    this.ready = false;
    if (p) {
      clearTimeout(p.timer);
      p.reject(new Error(`serve child died: ${why}`));
    }
  }

  async _waitReady() {
    if (this.ready) return;
    const deadline = Date.now() + READY_TIMEOUT_MS;
    while (!this.ready && !this.dead && Date.now() < deadline) {
      await new Promise((r) => setTimeout(r, 5));
    }
    if (this.dead) throw new Error("serve child died before ready");
    if (!this.ready) {
      this._die("ready timeout");
      throw new Error("serve child boot timed out");
    }
  }

  // Send ONE request line, await the matching reply. Serialized via the
  // queue so reads on the shared stdout stream never interleave.
  request(requestLine) {
    const run = async () => {
      this.spawnIfNeeded();
      await this._waitReady();
      return await new Promise((resolve, reject) => {
        const timer = setTimeout(() => {
          this._die("request timeout");
        }, REQUEST_TIMEOUT_MS);
        this.pending = { resolve, reject, timer };
        try {
          const ok = this.proc.stdin.write(requestLine + "\n");
          if (!ok) {
            // Backpressure is fine ; a hard write failure throws below.
          }
        } catch (e) {
          this._die(`write error: ${e.message}`);
        }
      });
    };
    // Chain on the queue ; clear the chain's rejection so one failed
    // request doesn't poison the next (which respawns a fresh child).
    const result = this.queue.then(run, run);
    this.queue = result.then(() => {}, () => {});
    return result;
  }
}

// Build the `Command k=v …` request line from command + attr-arg array
// (the same encodeAttrs output dispatch.mjs already produces).
export function buildRequestLine(command, attrArgs) {
  return [command, ...attrArgs].join(" ");
}

// Try a warm dispatch through the resident child for this root. Resolves
// with the parsed state object on success ; REJECTS on any failure so
// the caller falls back to a one-shot spawn. The child is keyed by
// aggregatesDir and lazily spawned on first use.
export async function warmDispatch(aggregatesDir, command, attrArgs) {
  let child = children.get(aggregatesDir);
  if (!child) {
    child = new ServeChild(aggregatesDir);
    children.set(aggregatesDir, child);
  }
  const line = buildRequestLine(command, attrArgs);
  return await child.request(line);
}
