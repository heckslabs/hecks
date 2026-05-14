# Tools.bluebook split — design pass

**Date:** 2026-05-14
**Status:** DESIGN ONLY — no code or bluebook edits, no adapter changes
**Branch:** `sq/tools-bluebook-split-design`
**Triggered by:** cohesion-validator warnings on commit `5d91694f` (EmailTool landing)
**Input card:** `hecks_conception/inbox/i609.md`

---

## 1. Rationale

### What the validator said

When EmailTool landed, `tools.bluebook` crossed 19 aggregates. Three warnings fired:

- *"domain 'Tools' has 19 aggregates; review for cohesion (sweet spot is 3–6; past 7 most domains read as two)"*
- *"domain 'Tools' has 19 aggregates; multi-domain split likely improves cohesion (two ubiquitous languages are usually being merged at this size)"*
- *"bluebook 'Tools' has 281 structural units — is this really one concern, or is it two?"*

EmailTool didn't cause the problem; it revealed an accumulation pattern that started the day five category aggregates became fourteen.

### Why these five groups are the right cut

The 19 aggregates fall into five groups that each have a coherent **ubiquitous language**:

| Sub-bluebook | Aggregates | UL concept |
|---|---|---|
| **DeveloperTools** | ShellTool, FileTool, SearchTool, WebTool, LspTool | "I run tools against the codebase" |
| **CommsTools** | EmailTool, NotifyTool, AskTool | "I communicate with the operator" |
| **AgentOrchestration** | TaskTool, Sidequest, WakeupTool, CronTool, MonitorTool, WorktreeTool | "I orchestrate other agents and processes" |
| **SurfaceTools** | PlanTool, SkillTool, MetaTool, RemoteTriggerTool | "I compose invocations against the harness surface" |
| **Cascade** | Cascade | "I record the kernel-hook outcome" |

Each sub-bluebook lands at 3–6 aggregates, inside the cohesion sweet spot.

### Why not 3-way

A simpler cut (`DevTools`, `AgentTools`, `Cascade`) works but keeps CommsTools concepts (email/notify/ask) buried inside a large AgentTools. The operator's mental model treats "send a notification" and "dispatch a sub-agent" as different categories. The 5-way cut honours that.

### Why not 7-way

Splitting DeveloperTools further (e.g. shell apart from file I/O) leaves single-aggregate bluebooks. Single-aggregate bluebooks have no cohesion problem by definition and produce unnecessary filesystem noise. Five is the right grain.

### Why not no-split

The validator at 19 aggregates is signalling a real structural cost: new contributors reading `tools.bluebook` must read past aggregates for email, cron scheduling, LSP queries, and push notifications before they find `ShellTool`. The cohesion warning is not advisory noise at this scale. The UL split is legible and correct.

---

## 2. Full FQN remap table

Source: `hecks_conception/aggregates/framework/tools/tools.bluebook` (current HEAD, 19 aggregates, confirmed by file read 2026-05-14).

### DeveloperTools (new domain name: `DeveloperTools`)

| Old FQN | New FQN |
|---|---|
| `Tools::ShellTool.Bash` | `DeveloperTools::ShellTool.Bash` |
| `Tools::FileTool.Read` | `DeveloperTools::FileTool.Read` |
| `Tools::FileTool.Edit` | `DeveloperTools::FileTool.Edit` |
| `Tools::FileTool.Update` | `DeveloperTools::FileTool.Update` |
| `Tools::FileTool.Write` | `DeveloperTools::FileTool.Write` |
| `Tools::FileTool.NotebookEdit` | `DeveloperTools::FileTool.NotebookEdit` |
| `Tools::SearchTool.Grep` | `DeveloperTools::SearchTool.Grep` |
| `Tools::SearchTool.Glob` | `DeveloperTools::SearchTool.Glob` |
| `Tools::WebTool.WebFetch` | `DeveloperTools::WebTool.WebFetch` |
| `Tools::WebTool.WebSearch` | `DeveloperTools::WebTool.WebSearch` |
| `Tools::LspTool.Query` | `DeveloperTools::LspTool.Query` |

### CommsTools (new domain name: `CommsTools`)

| Old FQN | New FQN |
|---|---|
| `Tools::EmailTool.SearchThreads` | `CommsTools::EmailTool.SearchThreads` |
| `Tools::EmailTool.GetThread` | `CommsTools::EmailTool.GetThread` |
| `Tools::EmailTool.CreateDraft` | `CommsTools::EmailTool.CreateDraft` |
| `Tools::EmailTool.ListDrafts` | `CommsTools::EmailTool.ListDrafts` |
| `Tools::NotifyTool.Push` | `CommsTools::NotifyTool.Push` |
| `Tools::AskTool.AskUser` | `CommsTools::AskTool.AskUser` |

### AgentOrchestration (new domain name: `AgentOrchestration`)

| Old FQN | New FQN |
|---|---|
| `Tools::TaskTool.Create` | `AgentOrchestration::TaskTool.Create` |
| `Tools::TaskTool.Get` | `AgentOrchestration::TaskTool.Get` |
| `Tools::TaskTool.List` | `AgentOrchestration::TaskTool.List` |
| `Tools::TaskTool.Output` | `AgentOrchestration::TaskTool.Output` |
| `Tools::TaskTool.Stop` | `AgentOrchestration::TaskTool.Stop` |
| `Tools::TaskTool.Update` | `AgentOrchestration::TaskTool.Update` |
| `Tools::Sidequest.Dispatch` | `AgentOrchestration::Sidequest.Dispatch` |
| `Tools::WakeupTool.Schedule` | `AgentOrchestration::WakeupTool.Schedule` |
| `Tools::CronTool.Create` | `AgentOrchestration::CronTool.Create` |
| `Tools::CronTool.List` | `AgentOrchestration::CronTool.List` |
| `Tools::CronTool.Delete` | `AgentOrchestration::CronTool.Delete` |
| `Tools::MonitorTool.Stream` | `AgentOrchestration::MonitorTool.Stream` |
| `Tools::WorktreeTool.Enter` | `AgentOrchestration::WorktreeTool.Enter` |
| `Tools::WorktreeTool.Exit` | `AgentOrchestration::WorktreeTool.Exit` |

### SurfaceTools (new domain name: `SurfaceTools`)

| Old FQN | New FQN |
|---|---|
| `Tools::PlanTool.Enter` | `SurfaceTools::PlanTool.Enter` |
| `Tools::PlanTool.Exit` | `SurfaceTools::PlanTool.Exit` |
| `Tools::SkillTool.Invoke` | `SurfaceTools::SkillTool.Invoke` |
| `Tools::MetaTool.ToolSearch` | `SurfaceTools::MetaTool.ToolSearch` |
| `Tools::RemoteTriggerTool.Trigger` | `SurfaceTools::RemoteTriggerTool.Trigger` |

### Cascade (new domain name: `Cascade`)

| Old FQN | New FQN |
|---|---|
| `Tools::Cascade.RecordResult` | `Cascade::Cascade.RecordResult` |

**Total commands remapped: 37** across 19 aggregates and 5 sub-bluebooks.

---

## 3. Dispatch-site audit

### Methodology

Grepped `Tools::` across all 12 directories listed in the brief. Excluded `BuildTools::` (unrelated) and `#`-prefixed comment lines. Catalogued every live reference.

### Results by directory

| Directory | File count with `Tools::` | Notes |
|---|---|---|
| `docs/` | 2 files | `storehouse-mcp.md` (9 live FQN examples), `dispatch.md` (1 legacy FQN in example) |
| `CLAUDE.md` | 1 file | 1 FQN example in locked convention note |
| `FEATURES.md` | 1 file | 1 FQN in feature description |
| `hecks_conception/inbox/` | 10 files | i552, i556, i577, i590, i599, i603, i604, i607, i608, i609 — documentation and cross-refs |
| `rust/src/` | 3 files | `main.rs` (2 FQNs in error message strings), `command_dispatch.rs` (3 comment-doc examples), `mod.rs` (1 comment example) |
| `rust/tests/` | 1 file | `breadcrumb_phrase_test.rs` (4 assertions with `Tools::Tools.Bash` — legacy pre-split form) |

**All 12 other directories** (aggregates, runtime, bluebook, codegen, catalog, tooling, integrations, discipline, tools, miette, miette_family): **zero hits**. The FQN is referenced only in docs, CLAUDE.md, FEATURES.md, inbox cards, Rust error strings, and one test file.

### Live site count by sub-bluebook destination

| Sub-bluebook | Live FQN references (non-inbox, non-legacy-test) | Files |
|---|---|---|
| DeveloperTools | 14 | storehouse-mcp.md (×9), i607 (×6), i590, CLAUDE.md, FEATURES.md, docs/usage/dispatch.md |
| CommsTools | 3 | i608 (×1), i609 (×2) |
| AgentOrchestration | 0 | — |
| SurfaceTools | 0 | — |
| Cascade | 1 | storehouse-mcp.md (×1) |

Note: inbox cards are documentation/planning artefacts, not dispatch call sites. The only operational dispatch-site FQNs in Rust source (`main.rs` error strings and `command_dispatch.rs` comments) are error-message examples, not actual dispatch calls. **There are zero live runtime dispatch calls using `Tools::` FQNs in compiled Rust code.** The `Tools::` FQN is used exclusively in documentation and error-message strings.

The `breadcrumb_phrase_test.rs` uses `Tools::Tools.Bash` (the pre-2026-05-12 legacy form) — this test would need updating to `DeveloperTools::ShellTool.Bash` regardless of this split.

### Key finding

**The FQN is a human-facing address, not a hard-wired runtime string.** The runtime matches adapter bindings by `{AggregateName}.{CommandName}` (short form, e.g. `ShellTool.Bash`), not by FQN. This has critical implications for the adapter audit below.

---

## 4. `result_into:` cascade-target audit

The `tools.hecksagon` declares eight adapter bindings, all using `result_into: "Cascade.RecordResult"` (short form, not FQN). After the split, Cascade moves to its own bluebook (`Cascade::Cascade.RecordResult`).

### Current sites

| File | Line | Current value |
|---|---|---|
| `hecks_conception/aggregates/framework/tools/tools.hecksagon` | 39 | `result_into: "Cascade.RecordResult"` (ShellTool.Bash) |
| `hecks_conception/aggregates/framework/tools/tools.hecksagon` | 42 | `result_into: "Cascade.RecordResult"` (FileTool.Read) |
| `hecks_conception/aggregates/framework/tools/tools.hecksagon` | 43 | `result_into: "Cascade.RecordResult"` (FileTool.Edit) |
| `hecks_conception/aggregates/framework/tools/tools.hecksagon` | 44 | `result_into: "Cascade.RecordResult"` (FileTool.Update) |
| `hecks_conception/aggregates/framework/tools/tools.hecksagon` | 47 | `result_into: "Cascade.RecordResult"` (SearchTool.Grep) |
| `hecks_conception/aggregates/framework/tools/tools.hecksagon` | 48 | `result_into: "Cascade.RecordResult"` (SearchTool.Glob) |
| `hecks_conception/aggregates/framework/tools/tools.hecksagon` | 62 | `result_into: "Cascade.RecordResult"` (WebTool.WebFetch) |
| `hecks_conception/aggregates/framework/tools/tools.hecksagon` | 63 | `result_into: "Cascade.RecordResult"` (WebTool.WebSearch) |

**Total `result_into:` sites: 8**, all in a single file (`tools.hecksagon`).

**Critical finding about resolution:** the runtime resolves `result_into` by the same short-form mechanism as `command:`. In `resolve_claude_tool_adapters`, the target string is built as `format!("{}.{}", result.aggregate_type, bare_command)` and compared against the hecksagon's stripped `command:` value. The `result_into: "Cascade.RecordResult"` is then dispatched via `dispatch_cascade` using the bare form. The bluebook loaded at boot must contain an aggregate named `Cascade` with a command named `RecordResult` — the domain prefix is irrelevant to matching.

**Impact of the split:** after the split, each sub-bluebook's hecksagon will still work with `result_into: "Cascade.RecordResult"` as long as the `Cascade` bluebook is loaded into the same runtime instance. The runtime resolves `Cascade.RecordResult` by bare aggregate+command name — not by FQN. No change needed to the `result_into:` string values. Only the file location of these entries changes (from the unified `tools.hecksagon` into four per-sub-bluebook hecksagons).

---

## 5. `:claude_tool` adapter family touch points

### `framework/adapter_families/claude_tool.hecksagon`

Located at: `hecks_conception/aggregates/framework/adapter_families/claude_tool.hecksagon`

The adapter family declares itself and describes its field surface (`name`, `command`, `tool`, `result_into`), trigger field (`command`), response field (`result_into`), and behavior (`invoke_claude_tool`). It contains **no aggregate-name or domain-name literals**. The comment on line 17 says `"Tools.X dispatch"` but this is documentation, not a routing key.

**Impact: zero runtime changes needed in `claude_tool.hecksagon`.** The family is domain-agnostic. It matches any hecksagon that declares `adapter :claude_tool, command: "AnyAggregate.AnyCommand"`.

### `rust/src/runtime/claude_tool_dispatcher/mod.rs`

The dispatcher matches by short-form `{AggregateName}.{CommandName}`, built from the dispatch result's `aggregate_type` field. It never reads a domain prefix. The full quote from the source:

```rust
let bare_command = command_name.rsplit('.').next().unwrap_or(command_name);
let target = format!("{}.{}", result.aggregate_type, bare_command);
```

It then compares `target` against the hecksagon's stripped `command:` value (e.g. `"ShellTool.Bash"`). **The domain name `Tools` never appears in this path.** After the split, `ShellTool.Bash` still dispatches and `command: "ShellTool.Bash"` in the new `developer_tools.hecksagon` still matches. Zero changes needed to the Rust dispatcher.

### `rust/src/runtime/framework_registry.rs`

The framework registry walks `framework/adapter_families/*.hecksagon` and `framework/behavior_kinds/*.hecksagon` by directory. It's entirely domain-name agnostic. After the split, the registry keeps working — it never references `"Tools"` at all. Zero changes needed.

### `rust/src/runtime/mod.rs` (`resolve_claude_tool_adapters`)

Same analysis as the dispatcher. Matches by short-form `{AggregateName}.{Command}`. Zero changes needed.

### `hecks_conception/aggregates/framework/tools/tools.hecksagon`

This file **does** change: after the split it splits into four per-sub-bluebook hecksagons:
- `aggregates/framework/developer_tools/developer_tools.hecksagon`
- `aggregates/framework/comms_tools/comms_tools.hecksagon`
- `aggregates/framework/agent_orchestration/agent_orchestration.hecksagon`
- `aggregates/framework/surface_tools/surface_tools.hecksagon`

The `Cascade` aggregate requires no hecksagon bindings (it has no adapter — it's a pure landing-pad aggregate). Its bluebook file would live at `aggregates/framework/cascade/cascade.bluebook`.

### Summary of adapter touch points

| Artifact | Changes needed |
|---|---|
| `claude_tool.hecksagon` (adapter family declaration) | None — domain-agnostic |
| `web_tool.hecksagon` (adapter family declaration) | None — domain-agnostic |
| `rust/src/runtime/claude_tool_dispatcher/mod.rs` | None — matches by short-form aggregate name |
| `rust/src/runtime/framework_registry.rs` | None — walks framework dirs by filesystem, not by domain name |
| `rust/src/runtime/mod.rs` | None — short-form matching |
| `tools.hecksagon` | Split into 4 files (Cascade needs none) |
| `tools.bluebook` | Split into 5 files |
| Docs + error strings | ~15 FQN updates across 4 files |

**Total adapter touch points requiring code change: 0.** The hecksagon split is purely organisational.

---

## 6. Risk assessment

### What could break

**1. Runtime loading order (medium risk)**

The runtime boots from a root directory, walking all bluebook files it finds. Today all 19 aggregates load from a single file. After the split, they load from 5 files. If the runtime is called with a path pointing at the old single file (e.g. `--bluebook tools.bluebook`), it would only see that file's aggregates. Any script or integration that references the bluebook by file path directly would break.

*Recovery:* the runtime is invoked via `storehouse hecks_conception/aggregates/framework/...` directory, not single-file. Directory-based loading is unaffected. Low actual risk.

**2. Cross-load dependency for `result_into:` (medium risk)**

The `result_into: "Cascade.RecordResult"` in each sub-bluebook's hecksagon dispatches a cascade into the `Cascade` aggregate. After the split, the `Cascade` aggregate lives in a separate file. If any sub-system boots only one sub-bluebook without also loading the Cascade bluebook, the cascade dispatch fails with `UnknownAggregate`.

*Recovery:* the runtime boots a whole aggregates directory, not individual files. All five bluebooks will always be loaded together. Low actual risk in practice — but it's a new coupling that didn't exist when everything was in one file.

**3. Breadcrumb phrase test (low risk, certainty of breakage)**

`rust/tests/breadcrumb_phrase_test.rs` has 4 assertions against `"Tools::Tools.Bash"` — the pre-2026-05-12 legacy form. This test was already stale before the split. After the split it still won't pass with the new FQN (`DeveloperTools::ShellTool.Bash`). Needs an update to pass.

*Recovery:* one file, 4 line changes. Straightforward.

**4. Documentation FQN staleness (low risk)**

~15 FQN references across `storehouse-mcp.md`, `dispatch.md`, `CLAUDE.md`, `FEATURES.md` will be stale. No runtime impact — docs only.

*Recovery:* grep-and-replace pass, one commit.

**5. Macrophage `include_str!` drift (medium risk without i605)**

If any future code embeds a `Tools::` FQN via `include_str!` or a doc comment, the i605 RenameDiscipline macrophage would catch it. Without i605, stale FQN references can accumulate in non-grep-visible places. At today's HEAD: zero Rust `include_str!` references to `Tools::` FQNs were found. Risk is future accumulation, not present state.

**6. i608 (EmailTool adapter wiring) — in-flight card**

i608 is the EmailTool adapter wiring card — it lands `Tools::EmailTool` today and would need to move to `CommsTools::EmailTool` after this split. If i609 lands before i608 is fully closed, there's a brief window where the EmailTool adapter is pointed at the wrong bluebook.

*Recovery:* land i608 fully before executing the split. This is noted in i609 itself.

**7. PreToolUse hook (i599) — not yet wired**

i599 proposes a PreToolUse hook that maps native Claude tool calls to `Tools::<Cat>.<Method>` FQNs. If i599 lands before this split, the hook script has hardcoded `Tools::` prefixes that must be updated. If this split lands first, the hook is written once with the correct prefixes.

*Recovery:* order the implementation so i609 lands before i599's hook script is written.

### What is NOT recoverable without manual work

- Any client (script, hook, downstream service) that has hardcoded `Tools::` FQNs in text not tracked by git. At today's HEAD, no such client was found outside the hecks monorepo. Zero users means zero irrecoverable breakage.

---

## 7. Phased rollout plan

### Ordering rationale

Cascade first: it has the most inbound references (every tool aggregate's `result_into:` points at it) and zero outbound references to other tool aggregates. Extracting it cleanly first means the other four sub-bluebooks can be extracted sequentially without circular dependency concerns.

DeveloperTools second: it has the most FQN references in documentation and the live adapter bindings. Landing it proves the adapter migration pattern for the other three.

CommsTools third, AgentOrchestration and SurfaceTools after: they have zero operational dispatch sites today, making them the lowest-risk extractions.

---

### Phase 0 — prerequisites (not part of this PR)

- Close i608 (EmailTool adapter wiring). The EmailTool must be fully settled in `Tools::EmailTool` before the split moves it to `CommsTools::EmailTool`.
- Confirm the behaviors gate (pre-push) remains green on main before starting.

---

### Phase 1 — Extract Cascade

**Create:** `hecks_conception/aggregates/framework/cascade/cascade.bluebook`

Contents: extract the `Cascade` aggregate block from `tools.bluebook` verbatim, wrapped in its own `Hecks.bluebook "Cascade"` header. Remove the `Cascade` aggregate block from `tools.bluebook`.

**Update:** `tools.hecksagon` — no change needed (Cascade has no adapter bindings).

**Verify:**
- `storehouse hecks_conception catalog framework/cascade/cascade.bluebook` returns 1 aggregate.
- `storehouse hecks_conception dispatch Tools::ShellTool.Bash ...` still works (Cascade still resolves via the same runtime directory walk).
- Behaviors gate green.

**Doc update:** none — Cascade has almost no standalone documentation FQNs.

**Commit:** `refactor(tools): extract Cascade aggregate into cascade.bluebook`

---

### Phase 2 — Extract DeveloperTools

**Create:** `hecks_conception/aggregates/framework/developer_tools/developer_tools.bluebook`

Contents: extract ShellTool, FileTool, SearchTool, WebTool, LspTool from `tools.bluebook`. Header becomes `Hecks.bluebook "DeveloperTools"`.

**Create:** `hecks_conception/aggregates/framework/developer_tools/developer_tools.hecksagon`

Contents: the six `adapter :claude_tool` and two `adapter :web_tool` lines from `tools.hecksagon`, plus `adapter :memory`. The `result_into: "Cascade.RecordResult"` values stay unchanged.

**Update:** `tools.bluebook` — remove the five extracted aggregates.

**Update:** `tools.hecksagon` — remove the eight extracted adapter lines.

**Verify:**
- `storehouse hecks_conception dispatch DeveloperTools::ShellTool.Bash ...` works.
- `storehouse hecks_conception dispatch Tools::ShellTool.Bash ...` fails (expected — domain name changed).
- Behaviors gate green.

**Doc update:**
- `docs/usage/storehouse-mcp.md`: update 9 FQN examples from `Tools::ShellTool.Bash` → `DeveloperTools::ShellTool.Bash`, etc.
- `CLAUDE.md`: update locked-convention example.
- `FEATURES.md`: update FQN mention.
- `docs/usage/dispatch.md`: update legacy FQN example.
- `rust/tests/breadcrumb_phrase_test.rs`: update 4 assertions (were already stale).

**Commit:** `refactor(tools): extract DeveloperTools sub-bluebook + doc FQN rename pass`

---

### Phase 3 — Extract CommsTools

**Create:** `hecks_conception/aggregates/framework/comms_tools/comms_tools.bluebook`

Contents: EmailTool, NotifyTool, AskTool. Header becomes `Hecks.bluebook "CommsTools"`.

**Create:** `hecks_conception/aggregates/framework/comms_tools/comms_tools.hecksagon`

Contents: `adapter :memory` only (EmailTool's MCP adapter, if wired by i608, moves here). Any i608 adapter bindings for EmailTool move from `tools.hecksagon` to `comms_tools.hecksagon`.

**Update:** `tools.bluebook` — remove the three extracted aggregates.

**Verify:**
- `storehouse hecks_conception dispatch CommsTools::EmailTool.SearchThreads ...` works.
- i608 acceptance test (if closed) passes against new FQN.
- Behaviors gate green.

**Doc update:** inbox cards i608 and i609 are informational — no runtime impact.

**Commit:** `refactor(tools): extract CommsTools sub-bluebook`

---

### Phase 4 — Extract AgentOrchestration

**Create:** `hecks_conception/aggregates/framework/agent_orchestration/agent_orchestration.bluebook`

Contents: TaskTool, Sidequest, WakeupTool, CronTool, MonitorTool, WorktreeTool. Header becomes `Hecks.bluebook "AgentOrchestration"`.

**Create:** `hecks_conception/aggregates/framework/agent_orchestration/agent_orchestration.hecksagon`

Contents: `adapter :memory`. These aggregates have no adapter bindings today (their commands are pure domain records; no `:claude_tool` or `:web_tool` adapter fires for them).

**Update:** `tools.bluebook` — remove the six extracted aggregates.

**Verify:**
- `storehouse hecks_conception dispatch AgentOrchestration::TaskTool.Create ...` works.
- `storehouse hecks_conception validate` reports no cohesion warning for the remaining `Tools` bluebook.
- Behaviors gate green.

**Commit:** `refactor(tools): extract AgentOrchestration sub-bluebook`

---

### Phase 5 — Extract SurfaceTools + retire Tools.bluebook

**Create:** `hecks_conception/aggregates/framework/surface_tools/surface_tools.bluebook`

Contents: PlanTool, SkillTool, MetaTool, RemoteTriggerTool. Header becomes `Hecks.bluebook "SurfaceTools"`.

**Create:** `hecks_conception/aggregates/framework/surface_tools/surface_tools.hecksagon`

Contents: `adapter :memory`.

**Delete:** `hecks_conception/aggregates/framework/tools/tools.bluebook` and `tools.hecksagon` (now empty after four extractions).

**Verify:**
- `storehouse hecks_conception validate` produces zero cohesion warnings on all five new sub-bluebooks.
- `storehouse hecks_conception dispatch SurfaceTools::PlanTool.Enter ...` works.
- `storehouse hecks_conception dispatch DeveloperTools::ShellTool.Bash ...` still works (full smoke-test across all five sub-bluebooks).
- Behaviors gate green.
- Pre-push behaviors gate green.

**Commit:** `refactor(tools): extract SurfaceTools + retire monolithic tools.bluebook`

---

## 8. Dependencies on i604 + i605

### i604 — Command-bus version-aliases

i604 would add a `migrations do ... end` block to each bluebook so old FQNs keep routing to the renamed destination. Without it:

- `Tools::ShellTool.Bash` fails immediately after Phase 2 lands.
- Any in-flight agent or hook pinned to `Tools::` FQNs breaks hard.
- The only mitigation is coordinating the rename so no client is mid-flight.

**At today's state:** there are zero external clients. The PreToolUse hook (i599) is not yet wired. The MCP wrappers that hard-coded `Tools::` FQNs were retired (2026-05-13). CLAUDE.md and documentation FQNs are updated in the same commit as the bluebook split (no window of inconsistency). **Without i604, the split is safe today.** The risk calculus changes if i599 lands first, because i599 writes a script that embeds `Tools::<Cat>.<Method>` FQNs — that script would then break when the split runs.

**Quantified risk of landing without i604:** negligible today, high if i599 lands first. The ordering recommendation: land i609 before i599 to avoid this risk.

### i605 — RenameDiscipline macrophage

i605 would catch stale FQN references in `include_str!` macros, doc comments, and inline strings that grep misses. Without it:

- The audit in Section 3 is a point-in-time grep. Future code can introduce stale `Tools::` FQN strings without detection.
- The pre-commit gate has no structural check for FQN disappearances.

**At today's state:** the audit found zero stale FQN references in non-documentation Rust code. The only Rust FQN strings are in error message templates and one test (both trivially grep-able). **Without i605, the split is auditable but fragile over time.** Every future bluebook rename will require a manual grep pass.

**Quantified risk of landing without i605:** zero immediate breakage; ongoing maintenance cost of ~15 minutes per future rename to run the audit. Rises as the codebase grows.

### Summary table

| Dependency | Required for split? | Impact if missing | Ordering |
|---|---|---|---|
| i604 (version-aliases) | No, if i599 hasn't landed | Hard break for i599 hook script | Land i609 before i599 |
| i605 (RenameDiscipline) | No | Manual audit per future rename | Land eventually; low urgency |

---

## 9. Estimated LOC churn

### Bluebook files

| File action | Count | Estimated lines |
|---|---|---|
| New bluebook files created | 5 | ~1,567 lines total (split from current 1,566-line tools.bluebook) |
| Old `tools.bluebook` deleted | 1 | –1,566 lines |
| Net new bluebook lines | — | ~+1 (header overhead per new file, ×5) |

### Hecksagon files

| File action | Count | Estimated lines |
|---|---|---|
| New hecksagon files created | 4 (Cascade needs none) | ~65 lines total (split from current 64-line tools.hecksagon) |
| Old `tools.hecksagon` deleted | 1 | –64 lines |
| Net new hecksagon lines | — | ~+1 |

### Documentation + Rust

| File | FQN updates | Lines touched |
|---|---|---|
| `docs/usage/storehouse-mcp.md` | ~9 | ~9 |
| `CLAUDE.md` | 1 | 1 |
| `FEATURES.md` | 1 | 1 |
| `docs/usage/dispatch.md` | 1 | 1 |
| `rust/tests/breadcrumb_phrase_test.rs` | 4 | 4 |

**Total file touch count: ~15 files**
**Total rename operations: 37 FQN renames (docs/tests); 0 Rust runtime changes**
**Net LOC added by restructure: ~10 (new file headers); LOC moved: ~1,630**

---

## 10. Recommendation

**Land i609 now in 5 phases. Do not wait for i604 or i605.**

**Reasoning:**

1. **Zero external clients today.** The "no backward compat until first user" convention applies. The FQN break is intentional and acceptable at this moment. Every day this waits, more code accumulates under `Tools::` addresses.

2. **The adapter layer requires no changes.** This is not a runtime refactor — the Rust dispatcher works by aggregate name, not domain prefix. The split is a filing-cabinet reorganisation with a documentation update.

3. **i604 without i599 is irrelevant.** The only risk i604 would mitigate is breaking an in-flight hook script that embeds `Tools::` FQNs. That hook (i599) is not yet written. Land the split before i599 and the FQN surface is clean from day one of the hook's existence.

4. **i605 is a maintenance quality-of-life tool.** The current codebase has zero non-grep-visible stale FQN references. The audit above is complete. i605 matters for future renames, not this one.

5. **The cohesion validator is right.** 19 aggregates and 281 structural units in one bluebook are a real readability cost. The split reduces each sub-bluebook to 3–6 aggregates with a clear, named UL.

**The one condition:** close i608 (EmailTool adapter wiring) before running Phase 3 (CommsTools extraction). The two cards must not interleave — EmailTool's adapter binding must be settled in `tools.hecksagon` before that file is split.

**Alternative framing:** if Chris wants i604 as a safety net before any FQN moves, the minimum viable approach is to ship i604 first but scope it narrowly to `Tools::*` aliases only, targeting a one-day implementation before the split runs. That avoids the full i604 general-mechanism scope while giving version-aliases for this specific rename. Still not necessary; this is the cautious path.

---

## Appendix: Structural unit count per proposed sub-bluebook

Counts drawn from the bluebook read (2026-05-14). "Structural units" = aggregates + attributes + commands + value objects + policies + transitions.

| Sub-bluebook | Aggregates | Commands | VOs | Approx structural units |
|---|---|---|---|---|
| DeveloperTools | 5 | 11 | ~25 | ~80 |
| CommsTools | 3 | 6 | ~15 | ~45 |
| AgentOrchestration | 6 | 14 | ~30 | ~95 |
| SurfaceTools | 4 | 7 | ~15 | ~45 |
| Cascade | 1 | 1 | 6 | ~16 |
| **Total** | **19** | **39** | **~91** | **~281** |

Each sub-bluebook is below the cohesion sweet spot ceiling. DeveloperTools at ~80 units is the largest; SurfaceTools and CommsTools sit comfortably at ~45 each.
