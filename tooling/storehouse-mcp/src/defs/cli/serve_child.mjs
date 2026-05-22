// serve_child.mjs — warm unix-socket CLIENT for the storehouse daemon.
//
// The universal door (storehouse__dispatch) used to spawn a fresh
// `storehouse <root> <cmd> …` process per call (~660ms boot every time).
// The first speedup spawned ONE resident `storehouse serve-stdio` child
// per MCP server — but Claude Code starts the MCP, so the warm child
// died on every Claude restart and re-paid the boot.
//
// This module is the fix : the warm process now lives as an OVERMIND
// DAEMON (`storehouse serve-socket <root>`), independent of Claude, on a
// unix domain socket. This module is a thin CLIENT that CONNECTS per
// dispatch — so a Claude/MCP restart rebuilds only this membrane while
// the daemon stays warm. No persistent child is spawned here anymore.
//
// ## Socket address — one source of truth
//
// The daemon binds a deterministic per-root path (Rust SipHash of the
// canonical root). The JS side can't reproduce that hash, so we shell
// `storehouse sock-path <root>` ONCE per root (~600ms cold) and cache
// it. Every subsequent dispatch is a pure socket round-trip.
//
// ## Protocol (must match rust/src/run_serve/)
//
// Request : one line written to the socket — `Command k=v k=v …`
//           (the same positional shape the one-shot CLI takes).
// Reply   : the daemon writes ONE sentinel-prefixed line back :
//             "\x1eRESULT " + json     — the answer
//             "\x1eERROR "  + json     — a handled dispatch error
//           then closes the connection. (The daemon's free-form
//           adapter/log output goes to ITS stdout, never the socket, so
//           the stream carries only the result line.)
//
// ## Fallback policy (mandatory — this is the universal door)
//
// CONNECT failure (daemon down : ENOENT / ECONNREFUSED) → reject so the
// caller falls back to a one-shot `storehouse <root> <cmd>` spawn. A
// connected-then-`\x1eERROR` reply is a REAL dispatch error, not a
// transport fault — surfaced as a rejection too (the caller's one-shot
// fallback reproduces the same error cleanly). A warm-path fault NEVER
// black-holes a dispatch.

import { spawn } from "node:child_process";
import net from "node:net";

const STOREHOUSE_BIN = process.env.STOREHOUSE_BIN || "storehouse";
const RESULT_SENTINEL = "\x1eRESULT ";
const ERROR_SENTINEL = "\x1eERROR ";
// Dispatches can be slow when LLM / tool adapters fire ; generous cap.
const REQUEST_TIMEOUT_MS = Number(process.env.STOREHOUSE_SERVE_TIMEOUT_MS || 30000);

// Cache of resolved socket paths, keyed by aggregates root. The value is
// a Promise<string> so concurrent first-dispatches share ONE sock-path
// spawn. A failed resolution clears the entry so the next call retries.
const sockPaths = new Map();

// Shell `storehouse sock-path <root>` once per root, caching the result.
function sockPathFor(aggregatesDir) {
  let p = sockPaths.get(aggregatesDir);
  if (p) return p;
  p = new Promise((resolve, reject) => {
    const child = spawn(STOREHOUSE_BIN, ["sock-path", aggregatesDir], {
      env: process.env,
      stdio: ["ignore", "pipe", "pipe"],
    });
    let out = "";
    let err = "";
    child.stdout.on("data", (d) => (out += d.toString()));
    child.stderr.on("data", (d) => (err += d.toString()));
    child.on("error", reject);
    child.on("close", (code) => {
      const path = out.trim();
      if (code === 0 && path) resolve(path);
      else reject(new Error(`sock-path failed (code ${code}): ${err.trim()}`));
    });
  });
  // Drop the cache entry on failure so a later call can retry.
  p.catch(() => sockPaths.delete(aggregatesDir));
  sockPaths.set(aggregatesDir, p);
  return p;
}

// Connect to the socket, send ONE request line, await the single
// sentinel-prefixed reply line. Resolves with the parsed state object on
// `\x1eRESULT` ; REJECTS on connect failure (daemon down → caller falls
// back) and on `\x1eERROR` (real dispatch error → caller's one-shot
// fallback reproduces it cleanly).
function socketRequest(sockPath, requestLine) {
  return new Promise((resolve, reject) => {
    let buf = "";
    let settled = false;
    const conn = net.createConnection(sockPath);

    const timer = setTimeout(() => fail(new Error("socket request timeout")), REQUEST_TIMEOUT_MS);

    const done = (fn, arg) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      try { conn.destroy(); } catch { /* already gone */ }
      fn(arg);
    };
    const fail = (e) => done(reject, e);

    conn.on("connect", () => {
      conn.write(requestLine + "\n");
    });
    conn.on("data", (d) => {
      buf += d.toString();
      let nl;
      while ((nl = buf.indexOf("\n")) !== -1) {
        const line = buf.slice(0, nl);
        buf = buf.slice(nl + 1);
        if (line.startsWith(RESULT_SENTINEL)) {
          let parsed = null;
          try {
            parsed = JSON.parse(line.slice(RESULT_SENTINEL.length));
          } catch (e) {
            fail(new Error(`unparseable socket reply: ${e.message}`));
            return;
          }
          done(resolve, parsed);
          return;
        }
        if (line.startsWith(ERROR_SENTINEL)) {
          // A handled dispatch error — reject so the caller falls back
          // to a clean one-shot spawn rather than returning a partial.
          fail(new Error(`daemon returned error: ${line.slice(ERROR_SENTINEL.length)}`));
          return;
        }
        // Any other line would be incidental — the daemon shouldn't emit
        // any over the socket, but tolerate + forward to stderr.
        if (line.length) process.stderr.write(line + "\n");
      }
    });
    // Connect failure (ENOENT / ECONNREFUSED) or premature close — the
    // daemon is down. Reject so the caller falls back to a one-shot.
    conn.on("error", (err) => fail(err));
    conn.on("close", () => fail(new Error("socket closed before reply")));
  });
}

// Build the `Command k=v …` request line from command + attr-arg array
// (the same encodeAttrs output dispatch.mjs already produces).
export function buildRequestLine(command, attrArgs) {
  return [command, ...attrArgs].join(" ");
}

// Try a warm dispatch through the resident DAEMON for this root. Resolves
// with the parsed state object on success ; REJECTS on any failure so the
// caller falls back to a one-shot spawn. Resolves the socket path once
// per root (cached), then connects per dispatch.
export async function warmDispatch(aggregatesDir, command, attrArgs) {
  const sockPath = await sockPathFor(aggregatesDir);
  const line = buildRequestLine(command, attrArgs);
  return await socketRequest(sockPath, line);
}
