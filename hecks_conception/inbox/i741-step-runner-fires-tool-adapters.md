---
category: runtime-gap
status: resolved
tier: 1
story: runnable-usecases
---
# i741 — Story/Sprint.Execute step-runner must fire tool adapters

## The gap (empirically proven)
The use-case step-runner does NOT fire :claude_tool / :mcp / :web_tool
adapters. Path: story_runtime::storehouse_execute (and sprint_execute) ->
storehouse_router::route -> run::run_script. A step whose phrase is a tool
command (ShellTool.Bash, FileTool.Edit/Read, EmailTool.*) gets its command
dispatched and its event recorded (exit 0) but the SIDE-EFFECT adapter never
fires — the tool does nothing. So every tool-step use case is green-no-matter-
what. Proven: a ShellTool.Bash step that touches a file through Story.Execute
does NOT create the file; the SAME Tools::ShellTool.Bash via direct dispatch
DOES (timeline shows "1 adapter · claude_tool:bash ✓").

## Diagnosis (where the fix lives)
- DIRECT path that FIRES adapters: dispatch_hecksagon() in rust/src/main.rs
  (the `storehouse <root> Aggregate.Command` handler).
- STEP-RUNNER path that does NOT: run::run_script in rust/src/run.rs, which
  boots Runtime::boot_with_data_dir + AdapterRegistry::from_hecksagon and
  dispatches, but omits whatever tool-adapter resolution dispatch_hecksagon
  does AROUND/AFTER rt.dispatch. The resolvers (resolve_claude_tool_adapters
  etc., runtime/mod.rs ~707-845) are the firing mechanism; confirm whether
  dispatch_hecksagon invokes them post-dispatch and run_script doesn't.
- FIX: make run_script mirror dispatch_hecksagon's tool-adapter wiring so a
  tool step fires its adapter identically to direct dispatch.

## Acceptance test
rm -f /tmp/uc_adapter_probe.txt ; author a probe use case with one step
ShellTool.Bash {command: touch /tmp/uc_adapter_probe.txt} on a throwaway
story ; Plan::Story.Execute id=<story> use_case_count=1 ; the file MUST exist
after. Then re-run Plan::Sprint.Execute id=1 and report the honest per-card
verdict (i594/i608/i610 EmailTool likely RED — :mcp may genuinely not fire;
filetool-edit-multiline should go GREEN — multiline Edit works on direct).

## Why this is the real sprint-acceptance blocker
Until this lands, CurrentSprint.execute's green is only real for QUERY-step
cards (~18, which genuinely execute reads). Tool-step cards are hollow. This
is the heart of the runnable-usecases story.

## Do it governed
Best done in a FRESH session where bin/governed-door-hook actually bites —
so the work itself is governed. Related: i594 (:mcp adapter never fires even
on direct dispatch), i656 (all tools through storehouse).
