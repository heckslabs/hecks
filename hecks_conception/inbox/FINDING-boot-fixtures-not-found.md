# FINDING — boot pipeline can't find its system_prompt / agent_defs fixtures (2026-07-02)

*Surfaced during the boot-establishment keystone's live boot smoke. PRE-EXISTING,
unrelated to the keystone (the keystone is the CompleteBoot dispatch at the tail).
Not folded into the keystone commit — filed for a focused fix.*

## Symptom
A real boot (`storehouse run runtime/boot/bluebook/boot.bluebook being=Miette`)
completes exit 0 but prints two warnings from Phases 4 / 4b :
```
⚠ system_prompt: content fixtures not found at
   /Users/christopheryoung/Projects/miette/self/system_prompt/system_prompt_content.fixtures
   (No such file or directory)
⚠ agent_defs: fixtures not found at
   /Users/christopheryoung/Projects/hecks/hecks_conception/aggregates/framework/agent_instrumentation/agent_instrumentation.fixtures
   (No such file or directory)
```
So `GenerateSystemPrompt` (system_prompt.rs) and `RegenerateAgentDefs`
(agent_defs.rs) are no-ops at boot — the system prompt + subagent door blocks are
NOT being regenerated each boot as intended. Likely path drift (the fixtures
moved / were renamed, or the resolver's base path is stale).

## Why it matters
"Warnings are errors waiting to happen." These two phases exist so the system
prompt + the shared door convention can never drift from their fixtures. If the
fixtures aren't found, the regeneration silently skips and drift creeps back in.

## Next
Locate where `system_prompt_content.fixtures` + `agent_instrumentation.fixtures`
actually live now (grep the trees), fix the resolver path in
`rust/src/run_boot/system_prompt.rs` + `agent_defs.rs`, and add a boot smoke
assertion that both phases find their fixtures (no warning). Zero-warning boot.
