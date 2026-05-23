// dispatch_render_samples.mjs
//
// Prints sample renderings used by docs/dispatch_rendering.md. Not a
// test — just a tiny script that exercises the three acceptance
// shapes (simple, cascade, failure) and prints the resulting
// content[0].text so the doc carries the actual format, not a mock.
//
// Run : `node test/dispatch_render_samples.mjs` from storehouse-mcp/.

import { renderDispatch } from "../src/defs/cli/dispatch_render.mjs";

const simple = {
  ok: true, exit_code: 0, command: "Tools::ShellTool.Bash",
  stdout:
    `[2026-05-20T18:00:00Z] dispatch Tools::ShellTool.Bash#inv_a1 "cli smoke"\n` +
    `[2026-05-20T18:00:00Z] event ShellTool.BashRan#cli-smoke-bash\n` +
    `[2026-05-20T18:00:00Z] [claude_tool:bash] ok=true exit=0 output="hi\\n"\n` +
    `{"ok":true,"ShellTool":{"id":"cli-smoke-bash","shell_command":"echo hi","output":"hi\\n","exit_code":0,"ok":true}}\n`,
  stderr: "",
  state: { ok: true, ShellTool: { id: "cli-smoke-bash", shell_command: "echo hi", output: "hi\n", exit_code: 0, ok: true } },
  events: [
    { ts: "2026-05-20T18:00:00Z", kind: "dispatch", verb: "Tools::ShellTool.Bash", target: null, invocation_id: "inv_a1", description: "cli smoke" },
    { ts: "2026-05-20T18:00:00Z", kind: "event", verb: "ShellTool.BashRan", target: "ShellTool#cli-smoke-bash", invocation_id: "inv_a1" },
    { ts: "2026-05-20T18:00:00Z", kind: "adapter", verb: "claude_tool:bash", target: null, invocation_id: "inv_a1", ok: true, exit: 0, output: "hi\n" },
  ],
  auto_summary: "Tools::ShellTool.Bash → exit 0, 1 event (BashRan), 0 policies fired",
  duration_ms: 124,
};

const cascade = {
  ok: true, exit_code: 0, command: "Round::Round.StartRound",
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

const failure = {
  ok: false, exit_code: 2, command: "Nope::Nope.NoSuchThing",
  stdout: "",
  stderr: "Error: unknown command Nope::Nope.NoSuchThing in aggregates root /x",
  state: null,
  events: [],
  auto_summary: "Nope::Nope.NoSuchThing → dispatch did not start: Error: unknown command Nope::Nope.NoSuchThing in aggregates root /x",
  duration_ms: 38,
};

function section(label, result) {
  const bar = "═".repeat(70);
  process.stdout.write(`\n${bar}\n${label}\n${bar}\n`);
  process.stdout.write(renderDispatch(result) + "\n");
}

section("1 — Simple success (Tools::ShellTool.Bash)", simple);
section("2 — Cascade (Round.StartRound → policy → RunGrowth)", cascade);
section("3 — Failure (unknown command)", failure);
