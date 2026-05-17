// inbox_poll.mjs - the Inbox::Inbox.Check poll executor.
//
// [antibody-exempt: bin/inbox_poll.mjs - the program the :exec adapter
//  (framework/inbox/inbox.hecksagon, resolve_exec_adapters in
//  rust/src/runtime/mod.rs) invokes when Inbox::Inbox.Check dispatches.
//  The Inbox bluebook names the contract ; this Node script is its
//  impure executor (Gmail OAuth + historyId delta + card + draft).
//  NOT transitional : i629 closed end-to-end 2026-05-16, the loop
//  dispatch IS the poll. No bluebook can hold an OAuth/HTTP poller
//  body - kernel-adjacent by nature.]

//
// Locked spec (2026-05-15) :
//   - OAuth refresh (same mechanism proven by EmailTool.GetAttachment)
//   - Gmail historyId watermark : exact delta, no reprocessing, no
//     window blind spot ; clean start on first run (no backfill)
//   - known-correspondents-only (inbox_correspondents.json)
//   - per new inbound thread : write a card into the mapped project
//     inbox AND compose a draft reply (drafts only, never sent)
//   - never starts the work the mail requests : drafts + surfaces

import fs from "node:fs";
import path from "node:path";
import { execFileSync } from "node:child_process";

const HOME = process.env.HOME;
const TOKEN_PATH = HOME + "/.config/miette/google-oauth-token.json";
const STATE_PATH = HOME + "/miette-state/information/inbox_poll_state.json";
// drafts.heki : durable running total of email drafts Miette has composed.
// Upserted here (count += 1) after each successful Gmail draft create so
// the awake statusline can show ✉️ N. Path mirrors heki::resolve_info_dir().
const DRAFTS_HEKI = HOME + "/miette-state/information/drafts.heki";
const STOREHOUSE  = path.join(path.dirname(new URL(import.meta.url).pathname),
                              "../rust/target/release/storehouse");
const REGISTRY  = path.join(path.dirname(new URL(import.meta.url).pathname), "inbox_correspondents.json");
const API = "https://gmail.googleapis.com/gmail/v1/users/me";

function readJson(p, dflt) { try { return JSON.parse(fs.readFileSync(p, "utf8")); } catch { return dflt; } }
function writeJson(p, o) { fs.mkdirSync(path.dirname(p), { recursive: true }); fs.writeFileSync(p, JSON.stringify(o, null, 2)); }
function log(...a) { console.log("[inbox_poll]", ...a); }

async function accessToken() {
  const t = JSON.parse(fs.readFileSync(TOKEN_PATH, "utf8"));
  if (t.expiry && new Date(t.expiry).getTime() > Date.now() + 60000) return t.token;
  const body = new URLSearchParams({
    client_id: t.client_id, client_secret: t.client_secret,
    refresh_token: t.refresh_token, grant_type: "refresh_token",
  });
  const r = await fetch(t.token_uri || "https://oauth2.googleapis.com/token",
    { method: "POST", headers: { "Content-Type": "application/x-www-form-urlencoded" }, body });
  if (!r.ok) throw new Error("token refresh failed " + r.status);
  const j = await r.json();
  t.token = j.access_token;
  t.expiry = new Date(Date.now() + (j.expires_in || 3600) * 1000).toISOString();
  fs.writeFileSync(TOKEN_PATH, JSON.stringify(t, null, 2));
  log("token refreshed");
  return t.token;
}

const api = (tok, p) => fetch(API + p, { headers: { Authorization: "Bearer " + tok } }).then(r => r.json());

function headerVal(msg, name) {
  const h = (msg.payload && msg.payload.headers || []).find(x => x.name.toLowerCase() === name.toLowerCase());
  return h ? h.value : "";
}
function addrOf(from) {
  const m = from.match(/<([^>]+)>/);
  return (m ? m[1] : from).trim().toLowerCase();
}
function b64url(s) {
  return Buffer.from(s, "utf8").toString("base64").replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}
function nextCardId(dir) {
  let max = 0;
  try {
    for (const f of fs.readdirSync(dir)) {
      const m = f.match(/^i(\d+)\.md$/);
      if (m) max = Math.max(max, parseInt(m[1], 10));
    }
  } catch { fs.mkdirSync(dir, { recursive: true }); }
  return max + 1;
}

async function main() {
  const tok = await accessToken();
  const state = readJson(STATE_PATH, { last_history_id: null, seen_threads: [] });
  const reg = readJson(REGISTRY, { correspondents: [] }).correspondents;
  const byEmail = new Map(reg.map(c => [c.email.toLowerCase(), c]));

  if (!state.last_history_id) {
    const prof = await api(tok, "/profile");
    state.last_history_id = String(prof.historyId);
    writeJson(STATE_PATH, state);
    log("clean start : recorded historyId", state.last_history_id, "(no backfill)");
    return;
  }

  let pageToken = null, added = [], newHistoryId = state.last_history_id;
  do {
    const q = "/history?historyTypes=messageAdded&startHistoryId=" + state.last_history_id +
              (pageToken ? "&pageToken=" + pageToken : "");
    const h = await api(tok, q);
    if (h.error) { log("history.list error", JSON.stringify(h.error).slice(0, 200)); return; }
    if (h.historyId) newHistoryId = String(h.historyId);
    for (const rec of h.history || [])
      for (const ma of rec.messagesAdded || []) added.push(ma.message.id);
    pageToken = h.nextPageToken;
  } while (pageToken);

  const seen = new Set(state.seen_threads);
  let carded = 0;
  for (const id of [...new Set(added)]) {
    const msg = await api(tok, "/messages/" + id +
      "?format=metadata&metadataHeaders=From&metadataHeaders=Subject&metadataHeaders=Message-ID&metadataHeaders=Date");
    if (msg.error) continue;
    const labels = msg.labelIds || [];
    if (!labels.includes("INBOX") || labels.includes("DRAFT") || labels.includes("SENT")) continue;
    const from = headerVal(msg, "From"), email = addrOf(from);
    const corr = byEmail.get(email);
    if (!corr) continue;
    if (seen.has(msg.threadId)) continue;
    seen.add(msg.threadId);

    const subject = headerVal(msg, "Subject") || "(no subject)";
    const dir = path.join(HOME, corr.inbox);
    const n = nextCardId(dir);
    const today = new Date().toISOString().slice(0, 10);
    const card = `---\nref: i${n}\nstatus: open\npriority: normal\nposted_at: ${today}\nsource: inbox-poll\nfrom: ${corr.name} <${email}>\nthread: ${msg.threadId}\nvalue: 'Inbound from ${corr.name} : ${subject.replace(/'/g, "")}. Draft acknowledgement composed ; full reply + any work pending conscious review.'\n---\n\n# i${n} — ${corr.name} : ${subject}\n\nArrived ${today} via the inbox poll (thread \`${msg.threadId}\`).\nA draft acknowledgement is in Drafts. The full reply, and any work\nthis asks for, are pending conscious review : the poll drafts and\nsurfaces, it does not start the work.\n`;
    fs.writeFileSync(path.join(dir, `i${n}.md`), card);

    const reSub = /^re:/i.test(subject) ? subject : "Re: " + subject;
    const msgId = headerVal(msg, "Message-ID");
    const first = corr.name.split(" ")[0];
    const bodyText =
      `${first},\n\nGot this, and it is logged on our side. Nothing is lost. ` +
      `I will follow up properly with a full reply shortly.\n\nWarmly,\nMiette\n`;
    const mime =
      `To: ${email}\r\nSubject: ${reSub}\r\n` +
      (msgId ? `In-Reply-To: ${msgId}\r\nReferences: ${msgId}\r\n` : "") +
      `Content-Type: text/plain; charset=UTF-8\r\n\r\n${bodyText}`;
    const dr = await fetch(API + "/drafts", {
      method: "POST",
      headers: { Authorization: "Bearer " + tok, "Content-Type": "application/json" },
      body: JSON.stringify({ message: { raw: b64url(mime), threadId: msg.threadId } }),
    }).then(r => r.json());
    log(`card i${n} -> ${corr.inbox} ; draft ${dr.id ? "ok" : "FAILED " + JSON.stringify(dr).slice(0,120)} ; ${corr.name} : ${subject}`);
    // Bump drafts.heki counter only on a confirmed draft (dr.id truthy).
    // Defensive : heki write failure must not abort the poll.
    if (dr.id) {
      try {
        const prev = (() => {
          try {
            return parseInt(
              execFileSync(STOREHOUSE, ["heki", "latest-field", DRAFTS_HEKI, "count"],
                           { encoding: "utf8" }).trim(), 10) || 0;
          } catch { return 0; }
        })();
        execFileSync(STOREHOUSE,
          ["heki", "upsert", DRAFTS_HEKI, "--reason", "inbox poll drafted reply",
           `count=${prev + 1}`],
          { encoding: "utf8" });
        log(`drafts.heki updated : count=${prev + 1}`);
      } catch (e) {
        log("[warn] drafts.heki upsert failed (non-fatal):", e.message);
      }
    }
    carded++;
  }

  state.last_history_id = newHistoryId;
  state.seen_threads = [...seen].slice(-500);
  writeJson(STATE_PATH, state);
  log(`done : ${carded} new thread(s) carded+drafted ; watermark ${state.last_history_id}`);
}

// --loop <secs> : run forever on a cadence (overmind-supervised
// transitional member). One-shot otherwise (manual / bus dispatch).
const loopArg = process.argv.indexOf("--loop");
if (loopArg !== -1) {
  const secs = parseInt(process.argv[loopArg + 1], 10) || 900;
  const tick = async () => { try { await main(); } catch (e) { console.error("[inbox_poll] ERROR", e.message); } };
  await tick();
  setInterval(tick, secs * 1000);
} else {
  main().catch(e => { console.error("[inbox_poll] FATAL", e.message); process.exit(1); });
}
