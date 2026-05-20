// dispatch_render_test.mjs
//
// Unit smoke for dispatch_render.mjs. Feeds hand-crafted result
// objects — no storehouse subprocess — so it runs in milliseconds
// and exercises the three acceptance shapes the task calls out :
//
//   1. Simple success — Tools::ShellTool.Bash, one event, no
//      policies, no cascade. Asserts the headline, the timeline
//      tree, the auto-summary tail.
//   2. Cascade — a Round.StartRound-shape : dispatch → event →
//      policy → another dispatch. Asserts both invocations show in
//      the tree, the policy line carries an arrow.
//   3. Failure — ok=false with stderr text. Asserts the failure
//      block surfaces the stderr line and the headline shows ✗.
//
// Run : `node test/dispatch_render_test.mjs` from storehouse-mcp/.
// Exits 0 on green, non-zero on assertion failure.

import { renderDispatch } from "../src/defs/cli/dispatch_render.mjs";
import { unrecognisedLines } from "../src/defs/cli/dispatch_render/util.mjs";

let failed = 0;
function ok(label) { process.stderr.write(`ok   ${label}\n`); }
function fail(label, detail) {
  failed++;
  process.stderr.write(`FAIL ${label}: ${detail}\n`);
}
function truthy(v, label) { v ? ok(label) : fail(label, `expected truthy got ${JSON.stringify(v)}`); }
function contains(haystack, needle, label) {
  haystack && haystack.includes(needle)
    ? ok(label)
    : fail(label, `did not find ${JSON.stringify(needle)} in ${JSON.stringify(haystack).slice(0, 200)}`);
}
function notContains(haystack, needle, label) {
  haystack && haystack.includes(needle)
    ? fail(label, `found ${JSON.stringify(needle)} but shouldn't`)
    : ok(label);
}

// ---- 1. simple success ----------------------------------------------

const simple = {
  ok: true,
  exit_code: 0,
  command: "Tools::ShellTool.Bash",
  aggregates_dir: "/x",
  stdout:
    `[2026-05-20T18:00:00Z] dispatch Tools::ShellTool.Bash#inv_a1 "cli smoke"\n` +
    `[2026-05-20T18:00:00Z] event ShellTool.BashRan#cli-smoke-bash\n` +
    `{"ok":true,"ShellTool":{"id":"cli-smoke-bash","shell_command":"echo hi","output":"hi\\n","exit_code":0,"ok":true}}\n`,
  stderr: "",
  state: { ok: true, ShellTool: { id: "cli-smoke-bash", shell_command: "echo hi", output: "hi\n", exit_code: 0, ok: true } },
  events: [
    { ts: "2026-05-20T18:00:00Z", kind: "dispatch", verb: "Tools::ShellTool.Bash", target: null, invocation_id: "inv_a1", description: "cli smoke" },
    { ts: "2026-05-20T18:00:00Z", kind: "event", verb: "ShellTool.BashRan", target: "ShellTool#cli-smoke-bash", invocation_id: "inv_a1" },
  ],
  auto_summary: "Tools::ShellTool.Bash → exit 0, 1 event (BashRan), 0 policies fired",
  duration_ms: 124,
};

{
  const text = renderDispatch(simple);
  contains(text, "✓", "simple: headline has ok icon");
  contains(text, "Tools::ShellTool.Bash", "simple: headline names the verb");
  contains(text, "exit 0", "simple: headline reports exit 0");
  contains(text, "1 event", "simple: headline reports 1 event");
  contains(text, "124 ms", "simple: headline includes duration_ms");
  contains(text, "Timeline", "simple: timeline section header");
  contains(text, "└─ event ShellTool.BashRan", "simple: leaf event line uses box-drawing");
  contains(text, "State", "simple: state section present");
  contains(text, "shell_command=", "simple: state lists shell_command");
  contains(text, "— Tools::ShellTool.Bash → exit 0", "simple: auto_summary tail rendered");
  notContains(text, "[", "simple: no ANSI escape sequences");
}

// ---- 2. cascade with policy + nested dispatch ------------------------

const cascade = {
  ok: true,
  exit_code: 0,
  command: "Round::Round.StartRound",
  aggregates_dir: "/x",
  stdout:
    `[2026-05-20T18:00:00Z] dispatch Round::Round.StartRound#inv_r1\n` +
    `[2026-05-20T18:00:00Z] event Round.RoundStarted#6\n` +
    `[2026-05-20T18:00:00Z] policy GrowOnStart on Round.RoundStarted#6 -> RunGrowth\n` +
    `[2026-05-20T18:00:00Z] dispatch Round::Round.RunGrowth#inv_r2\n` +
    `[2026-05-20T18:00:00Z] event Round.GrowthComplete#6\n` +
    `{"ok":true,"Round":{"id":"6","stage":"growth"}}\n`,
  stderr: "",
  state: { ok: true, Round: { id: "6", stage: "growth" } },
  events: [
    { ts: "2026-05-20T18:00:00Z", kind: "dispatch", verb: "Round::Round.StartRound", target: null, invocation_id: "inv_r1" },
    { ts: "2026-05-20T18:00:00Z", kind: "event", verb: "Round.RoundStarted", target: "Round#6", invocation_id: "inv_r1" },
    { ts: "2026-05-20T18:00:00Z", kind: "policy", verb: "GrowOnStart", target: "Round.RoundStarted#6", invocation_id: "inv_r1", dispatched: "RunGrowth" },
    { ts: "2026-05-20T18:00:00Z", kind: "dispatch", verb: "Round::Round.RunGrowth", target: null, invocation_id: "inv_r2" },
    { ts: "2026-05-20T18:00:00Z", kind: "event", verb: "Round.GrowthComplete", target: "Round#6", invocation_id: "inv_r2" },
  ],
  auto_summary: "Round::Round.StartRound → exit 0, 2 events (RoundStarted, GrowthComplete), 1 policy (GrowOnStart) fired",
  duration_ms: 412,
};

{
  const text = renderDispatch(cascade);
  contains(text, "✓ Round::Round.StartRound", "cascade: headline ok + verb");
  contains(text, "2 events", "cascade: headline counts 2 events");
  contains(text, "1 policy", "cascade: headline counts 1 policy");
  contains(text, "policy GrowOnStart", "cascade: policy line present");
  contains(text, "⇢ RunGrowth", "cascade: policy line has arrow + dispatched");
  contains(text, "Round.StartRound#inv_r1", "cascade: root invocation labelled");
  contains(text, "Round.RunGrowth#inv_r2", "cascade: second invocation labelled");
  // Both invocation groups should appear ; the renderer separates
  // them with a blank line so the tree reads in chains.
  const idxR1 = text.indexOf("Round.StartRound#inv_r1");
  const idxR2 = text.indexOf("Round.RunGrowth#inv_r2");
  truthy(idxR1 < idxR2, "cascade: invocation groups ordered by appearance");
}

// ---- 3. failure ------------------------------------------------------

const failure = {
  ok: false,
  exit_code: 2,
  command: "Nope::Nope.NoSuchThing",
  aggregates_dir: "/x",
  stdout: "",
  stderr: "Error: unknown command Nope::Nope.NoSuchThing in aggregates root /x",
  state: null,
  events: [],
  auto_summary: "Nope::Nope.NoSuchThing → dispatch did not start: Error: unknown command Nope::Nope.NoSuchThing in aggregates root /x",
  duration_ms: 38,
};

{
  const text = renderDispatch(failure);
  contains(text, "✗", "failure: headline has fail icon");
  contains(text, "Nope::Nope.NoSuchThing", "failure: headline names the failed verb");
  contains(text, "dispatch failed", "failure: failure block present");
  contains(text, "unknown command", "failure: stderr text surfaced");
  contains(text, "— Nope::Nope.NoSuchThing → dispatch did not start", "failure: auto_summary tail rendered");
  notContains(text, "Timeline", "failure: no timeline section when no events");
}

// ---- 4. adapter failure --------------------------------------------

const adapterFail = {
  ok: false,
  exit_code: 1,
  command: "Tools::ShellTool.Bash",
  aggregates_dir: "/x",
  stdout:
    `[2026-05-20T18:00:00Z] dispatch Tools::ShellTool.Bash#inv_x1\n` +
    `[2026-05-20T18:00:00Z] [claude_tool:bash] ok=false exit=127 output="" error="command not found: zzz"\n` +
    `{"ok":false,"error":"adapter failed"}\n`,
  stderr: "",
  state: { ok: false, error: "adapter failed" },
  events: [
    { ts: "2026-05-20T18:00:00Z", kind: "dispatch", verb: "Tools::ShellTool.Bash", target: null, invocation_id: "inv_x1" },
    { ts: "2026-05-20T18:00:00Z", kind: "adapter", verb: "claude_tool:bash", target: null, invocation_id: "inv_x1", ok: false, exit: 127, error: "command not found: zzz" },
  ],
  auto_summary: "Tools::ShellTool.Bash → exit 1, 0 events emitted",
  duration_ms: 50,
};

{
  const text = renderDispatch(adapterFail);
  contains(text, "✗", "adapterFail: headline has fail icon");
  contains(text, "claude_tool:bash failed", "adapterFail: failure block names channel");
  contains(text, "command not found", "adapterFail: adapter error surfaced");
  contains(text, "📞 claude_tool:bash", "adapterFail: timeline has phone icon for adapter");
  contains(text, "exit=127", "adapterFail: timeline adapter exit code shown");
}

// ---- 5. unrecognised tts: line surfaces in raw appendix --------------

const tts = {
  ok: true,
  exit_code: 0,
  command: "Voice::Voice.Speak",
  aggregates_dir: "/x",
  stdout:
    `[2026-05-20T18:00:00Z] dispatch Voice::Voice.Speak#inv_v1\n` +
    `[2026-05-20T18:00:00Z] event Voice.Spoke#1\n` +
    `[2026-05-20T18:00:00Z] [tts:elevenlabs] ok=true audio_path="/tmp/x.mp3"\n` +
    `{"ok":true,"Voice":{"id":"1","last_text":"bonjour"}}\n`,
  stderr: "",
  state: { ok: true, Voice: { id: "1", last_text: "bonjour" } },
  events: [
    { ts: "2026-05-20T18:00:00Z", kind: "dispatch", verb: "Voice::Voice.Speak", target: null, invocation_id: "inv_v1" },
    { ts: "2026-05-20T18:00:00Z", kind: "event", verb: "Voice.Spoke", target: "Voice#1", invocation_id: "inv_v1" },
    // tts: adapter NOT in events (digest doesn't parse that channel yet)
  ],
  auto_summary: "Voice::Voice.Speak → exit 0, 1 event (Spoke), 0 policies fired",
  duration_ms: 200,
};

{
  const text = renderDispatch(tts);
  contains(text, "Raw output", "tts: raw appendix surfaces unparsed lines");
  contains(text, "tts:elevenlabs", "tts: appendix carries the tts adapter line");
  notContains(text, '{"ok":true,"Voice"', "tts: trailing JSON state filtered from raw appendix");
}

// ---- internals : unrecognisedLines ----------------------------------

{
  const lines = unrecognisedLines(
    `[ts] dispatch X.Y#1\n[ts] event Q.Z#1\nrandom passthrough\n{"ok":true}\n`,
    [],
  );
  truthy(lines.includes("random passthrough"), "unrecognisedLines keeps passthrough");
  truthy(!lines.some((l) => l.includes("dispatch X.Y")), "unrecognisedLines drops dispatch line");
  truthy(!lines.some((l) => l.includes('"ok":true')), "unrecognisedLines drops state JSON");
}

if (failed > 0) {
  process.stderr.write(`\n${failed} dispatch_render check(s) FAILED\n`);
  process.exit(1);
}
process.stderr.write("\nall dispatch_render checks passed\n");
