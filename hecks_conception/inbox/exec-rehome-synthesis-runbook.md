# Runbook — :exec re-homing (hecksagon-first synthesis) (2026-06-28)

## Why
Chris's standard (now recorded : ChrisYoung.DeclareStandard + standards.md +
system_prompt.md) : **Hecksagon-first — impure edges live in the hecksagon, never
a bluebook policy.** A past session (mine) retired the `:exec` adapter family
WITHOUT his approval, migrating 4 impure edges into bluebook policies firing
`Primitive::Process.Spawn`. He wants them back in the hexagon — as `:exec`
adapters — but WITHOUT reviving the bespoke per-family Rust resolver. Hence the
synthesis : `adapter :exec` is the hecksagon declaration ; it desugars to the
generic `Process.Spawn` primitive (one spawn path, no per-family code).

## Archaeology (the two retirement slices)
- `1fa95018` (May 22) — added `Primitive::Process.Spawn` + policy `with` literal
  args ; deleted `resolve_exec_adapters` ; migrated fibroblast.
- `bacc0692f` (May 22) — added aggregate-qualified `on "Agg.Event"` (gap #1b) ;
  migrated the remaining 3 (inbox poll, process-health sweep, heal).
- The PARSER still parses `adapter :exec` into a generic `IoAdapter{kind:"exec",
  options}` (hecksagon_parser.rs `absorb_adapter` default arm, ~line 233). It is
  parsed-but-dangling : no runtime arm executes it (`adapter_io.rs` has no exec).

## The blueprint (deleted resolve_exec_adapters, the proven shape)
Generic, NOT per-family : after a command completes, build
`target = "{aggregate_type}.{bare_command}"`, find every `:exec` IoAdapter whose
`command:` option == target, and for each run the `exec:` + cascade the
(id, output, exit_code, ok) into `result_into:`. The id join key is the
originating invocation id. It reused `exec_dispatcher::dispatch` (the SAME
kernel-floor leaf `resolve_primitive_spawn` uses) — so the only delta the
synthesis adds is : dispatch the `Primitive::Process.Spawn` COMMAND instead of
calling `exec_dispatcher` directly. One spawn path.

## The old `:exec` semantics (IMPORTANT — fires on COMMAND completion, not an event)
Old `adapter :exec, command: "ProcessMacrophage.Sweep", exec: "...", result_into:`
fired when the **Sweep command** completed (keyed `aggregate_type.bare_command`),
NOT on the `Swept` event. The policy migration mapped `command: "X.Sweep"` ->
`on "X.Swept"` (the emitted event). The synthesis restores the COMMAND-completion
semantics (simpler : no command->event mapping needed ; the arm fires in the
post-dispatch hook by command name).

## Implementation steps (mechanical)
1. **Runtime arm** (rust/src/runtime/mod.rs, EXEMPT) — reinstate a generic
   `resolve_exec_adapters(&mut self, result, command_name, attrs)` called from
   the SAME post-command hook the cascade/policy resolution runs in. For each
   matching `:exec` IoAdapter, DISPATCH `Hecks::Framework::Primitive::Process.Spawn`
   with `cmd = exec`, `result_into = result_into`, `id = invocation_id` (reuse
   the existing primitive path ; do NOT call exec_dispatcher directly). ~30 lines.
2. **Parser parity** — confirm both parsers capture `:exec` options
   (command/exec/result_into). Rust default arm already does ; verify
   ruby/hecksagon.rb parses `adapter :exec, ...` identically (hecksagon IR
   parity gate). Add if missing.
3. **Migrate the 4 bindings** back to hecksagon `:exec` adapters ; DELETE the
   corresponding bluebook policies :
   - process_health : RunSweepOnSwept, RunHealOnHealRequested -> `adapter :exec`
     (command: ProcessMacrophage.Sweep / .Heal).
   - inbox poll : the inbox `Process.Spawn` policy -> `adapter :exec`.
   - fibroblast : RunSweepOnSweepRan -> `adapter :exec`.
4. **Reaper** (this session's uncommitted work) — instead of RunReapOnSwept
   policy, declare `adapter :exec, command: "ProcessMacrophage.Sweep",
   exec: "bin/process_health_reap", result_into: "...RecordResult"` in
   process_health.hecksagon. (Two `:exec` adapters on Sweep : sweep + reap.)
   Keep runaway_after_seconds attr + RunawayWindow VO + the behavior + the
   bin script (all already written, validated 21/21).
5. **Gate** : cargo test --release (hecksagon IR parity + runtime), storehouse
   integrity, all .behaviors. Restart the 4 daemons ; verify each `:exec` fires
   its script (storehouse.log shows the spawn) and 0 UnknownCommand.

## Risk / notes
- EXEMPT kernel (runtime/mod.rs) + parser parity (ruby+rust) — byte-precise.
- The post-dispatch hook call site is where the retired call lived ; git show
  1fa95018^ for the exact call site + the full function body.
- Do NOT call exec_dispatcher directly (that's the non-synthesis form) —
  dispatch Process.Spawn so there is ONE spawn path (the standard's intent).
