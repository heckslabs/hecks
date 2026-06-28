# RUNBOOK: fold the governed-door barrier back into the macrophage (Option A)

## STATUS UPDATE 2 (2026-06-26) — follow-ups 1 & 2 LANDED ; item 3 HELD

Merged to main : `74eb83163` (items 1+2), on top of the Stage-2 merge `2c10f9fd6`.
- Item 1 (`6bab95bb5`) : native Write redirects to FileTool.Write (the parity-named
  door), not FileTool.Update.
- Item 2 (`231cbf4d1`) : the denial audit is now PER-RECORD on Macrophage::GovernedDoor
  (Pizzas Order shape — Record + ListAll + ByTool ; "count"/"by tool" are queries,
  not stored state). Dropped the Stage-2 singleton entity/counters/Deny/Complain.
  Hooks record Macrophage::GovernedDoor.Record. Governance::Violation is KEPT,
  reserved as the veto sink for the inbound Gate concept (gating.bluebook). Verified
  via behaviors (Pizzas way), never live dispatch.
- DESIGN NOTE : referencing Pizzas (Chris, 2026-06-26) reshaped the audit from a
  growing list_of-on-singleton (un-Pizzas : Pizzas only appends to BOUNDED lists)
  to per-record. And : do NOT touch Pizzas, only reference it. Persistence is
  dir:default + FQN — the store lives at the OS-default location by design ; never
  verify by live-dispatching against it (that pollutes the real store) — use behaviors.

ITEM 3 (`dc9467d43`, merged `b7b74239e`) DONE — retired Policy + EnforcementAdapter
+ the never-wired establishment cascade ; governance now holds ONLY Violation (the
Gate's reserved veto sink) ; hook fail-mode simplified to fail-open (Policy was
never established, so this matched the prior effective behavior). The boot part
was a no-op : BootCompleted has no producer, so nothing to revert in boot.bluebook.
VERIFIED no structural dep from the live authz/Gate work on Policy (middleware
ref is a test string ; gating ref is prose). Main rebuilt ; LookupDoor resolves
all 10 tools on main. THE WHOLE ARC IS LANDED.

FOLLOW-UP (when the Gate wires) : unify the two per-record denial audits —
Macrophage::GovernedDoor (barrier denials) and Governance::Violation (Gate veto
sink) are structurally identical ; they merge when the governed-door barrier
formally becomes a Gate.

--- superseded note ---
ITEM 3 was briefly HELD — it is entangled with the AuthIdentity + Gate authz work
landing LIVE on main (c9416f6aa Gate boundary + AuthIdentity ; f93e7a6c8 vetoing
middleware stack — authz runs through the door's gates). Policy IS authz-at-the-door
(deny-by-default + allow-list), so removing it now would fight the active authz
design. The governed-door barrier will likely BECOME a Gate ; Policy's fate +
the Violation/Denial sink unification belong with that design once it settles.
Also : the hook's fail-mode reads Governance::Policy.by_name, and boot establishment
touches live boot.bluebook — both need a plan, not a unilateral rip-out.

---

## STATUS (2026-06-26) — Stages 2+3+4 + the GovernedDoor-removal half of Stage 5 LANDED

Commit `703b9ee1b` on branch `worktree-governed-door-sibling` (worktree
`.claude/worktrees/governed-door-sibling`) — awaiting review/merge. Full gate
green : IR parity 135/136 + 111/111, hecksagon 126/126, world 9/11, golden
35/35, conceiver parity, lifecycle, behaviors 6/6 (sibling) + 10/10
(governance), antibody (hooks exempted), loc-ratchet. LookupDoor smoke resolves
all 10 native tools to the correct door (Agent→none).

DONE :
- Stage 2 : Macrophage::GovernedDoor sibling (governed_door.bluebook, a 2nd
  file of the Macrophage domain — multi-file domains are real, cf Conductor).
  LookupDoor PROJECTS the map (query.rs special-case, Macrophage-scoped,
  mirrors MatchInput) ; door_args derived from the command's own attributes.
- Stage 3 : 8 redirects_native declarations on tools.bluebook covering 10
  native tools (Edit governs Edit/MultiEdit/NotebookEdit ; Write→Update kept).
- Stage 4 : both hooks repointed to Macrophage::GovernedDoor.lookup_door.
- Stage 5 (partial) : removed the DUPLICATE Governance::GovernedDoor (it had
  been rehomed into governance by 426a3fec9, not deleted — it was the
  collision shadowing the projection) + its 10 Establish*Door boot policies +
  governance.fixtures + its behaviors tests.

KEY FINDINGS for the reader :
- Two design forks the runbook left open, resolved by fact : (a) multi-file
  domain → governed_door.bluebook declares `Hecks.bluebook "Macrophage"` →
  Macrophage::GovernedDoor ; (b) the collision was a true duplicate aggregate,
  fixed by removal (the branch IS also Macrophage-scoped).
- Behaviors harness runs its OWN in-memory query engine and does NOT exercise
  query.rs special-cases — so LookupDoor is verified by live CLI smoke, not a
  behaviors test. The sibling's command behaviors (Deny/Complain/StartSession)
  ARE behavior-tested.
- Write→door : kept the old fixtures mapping native Write→FileTool.Update.
  There is ALSO a FileTool.Write door ("for parity with Claude Code's Write")
  — a possible follow-up to repoint Write→FileTool.Write. Flagged, not changed.

WHAT REMAINS (Stage-5-proper, still fresh-head) :
- Remove the rest of the standalone governance domain : Policy /
  EnforcementAdapter / the Policy establishment cascade (Propose→Permit→
  Activate policies + 03f14e701 test) + the boot establishment wiring
  (bf380359d : CompleteBoot / BootCompleted). Violation may stay or fold in.
- Migrate the denial AUDIT onto the sibling : wire the Denial entity + counter
  increments (the same runtime-TODO FixturesRuntime has — singleton commands
  currently auto-id rather than key on :name), then repoint the hooks to
  record via Macrophage::GovernedDoor.Deny/Complain and drop
  Governance::Violation.Record. Until then the hooks still record to
  Governance::Violation (non-regressing).
- Stale prose : a few comments in immune_system / agent_discipline /
  artifact_claim bluebooks still describe GovernedDoor's old governance home.

---


Locked with Chris 2026-06-25, end of a long design dialogue. This SUPERSEDES the
whole "establish governance config as policy at boot" arc (bf380359d) AND the
GovernedDoor rehome (426a3fec9). It also retires the boot-establishment FINDING
(inbox/boot-establishment-not-wired-FINDING.md) — the mechanism it documents is
being deleted, not fixed.

## The decision, and the arc that produced it

The governed-door barrier (native tool -> storehouse-door redirect + deny-by-default)
is NOT a separate `framework/governance` domain, NOT a new grammar concept, and
NOT config seeded into a heki store at boot. **It is one more per-rule sibling of
the macrophage** — exactly like `FixturesRuntime`, `BluebookFirst`, `Warnings`, etc.
The prior session (me) wrongly pulled `GovernedDoor` OUT of the macrophage into a
standalone governance domain (426a3fec9) and then wrapped it in Policy + an
establishment cascade + heki seeding + boot wiring. Every one of those was the
same mistake compounding: treating one macrophage rule as its own domain with its
own persistence.

Chris peeled it back in order: why boot? why heki? act at the door — it's
middleware — native tools are denied in hooks because you can't trap them otherwise
— policies not fixtures — will this be bluebook, are we missing one? — it's not part
of macrophage? — we lean too much on fixtures in prod, look at Pizzas (zero
fixtures). Endpoint: model it the Pizzas way. Pizzas has NO fixtures — data comes
from commands, structure from the model, config values from .world, persistence
from adapters. The redirect is **domain structure on the door command**, read from
the IR, like `reference_to` / `emits`.

## Option A (chosen): the door command declares what native tool it replaces

The map is a PROJECTION of declarations in the IR, not data anywhere.

```
command "Bash" do            # Tools::ShellTool.Bash
  redirects_native "Bash"
  attribute :shell_command, ...
end
```

The macrophage projects native `Bash` -> this command ; **door_args is DERIVED
from the command's own attributes** (no second source, no door_args field in the
IR). A native tool with a `redirects_native` door is denied + redirected ; a tool
with none (control-plane, mcp__storehouse__*) is allowed. The deny-list IS the set
of `redirects_native` declarations.

## Build, test-first, in stages (each a commit through the full gate)

### Stage 1 — `redirects_native` command declaration (kernel primitive) — DONE + pushed
- SHIPPED : `0cebcd594` (added the field) + `1f0086755` (corrected it to a LIST).
  `pub redirects_native: Vec<String>` on `Command` (empty = not a door). A LIST
  because one door governs several native aliases (Edit door governs native Edit
  AND MultiEdit ; the deny-set IS the door-map keys, so a dropped alias = a
  governance hole). Surface : `redirects_native "Edit", "MultiEdit"`. door_args
  is derived in the projection, NOT stored. Parser splits quoted names ; Ruby
  builder takes a splat ; dump emits a JSON array. Parity 416/417, 35 goldens.
- Parse it in `parse_command` (parse_blocks_shape snippet `03_parse_command` or
  wherever `emits` is parsed — parse_blocks.rs:156 is the mirror : `emits` is
  `Option<String>` via `extract_string`). Add `redirects_native` the same way.
- dump.rs (`dump_shape`) Command serializer ; conceiver/generator.rs
  (`conceiver_generator_shape`) Command->bluebook roundtrip.
- 12 `Command {…}` construction sites need the new field (`redirects_native: None`):
  ir.rs, parse_blocks.rs, command_dispatch.rs, runtime/mod.rs, validator.rs,
  validator_corpus.rs, specializer/validator_checks{,_graph}.rs (several are
  generated — edit shapes, not the .rs). Compiler-guided (Command derives only
  Debug, Clone — no Default).
- RUBY PARITY : the Ruby command builder (ruby/hecks/dsl/command_builder.rb) +
  canonical_ir must carry `redirects_native` (the parity gate parses every
  bluebook ; tools.bluebook will use it). Mirror how `emits` flows.
- Regen goldens (`storehouse specialize all`), `cargo build -p storehouse-cli`,
  golden test, parity. Antibody : generated .rs are auto-exempt ; hand files need
  header markers (let the hook block, Chris decides per file).

### Stage 2 — the macrophage `GovernedDoor` sibling
- New `aggregates/discipline/immune_system/macrophage/governed_door.bluebook`
  (restores what 426a3fec9 deleted). Mirror `FixturesRuntime` shape
  (macrophage.bluebook:445) : singleton `identified_by :name`, denial counters,
  last-denied surface, a `Denial` audit ENTITY (the violation trail — real state,
  persisted via hexagon like Order->Heki), `Deny`/`Complain` commands (role `Hook`).
- `LookupDoor` query : projects the map from the IR — find the command whose
  `redirects_native == tool`, return its FQN (the door) + door_args derived from
  its attributes. MECHANISM FOUND (Stage-1 follow-up) : this is EXACTLY the
  `MatchInput` pattern in `rust/src/runtime/query.rs::resolve_query_qualified`
  — a query special-cased to scan `self.domain.aggregates[*].commands[*]` and
  return a computed projection (no instances). Add a `if query_name ==
  "LookupDoor"` branch beside MatchInput : iterate commands, match
  `cmd.redirects_native.as_deref() == Some(tool)`, return
  `{ door_equivalent: "<Context>::<Agg>.<cmd>", door_args: <attrs joined as
  name=<name>> }`. query.rs is a specializer target — edit the snippet holding
  the MatchInput branch, regen, golden. SEQUENCING NOTE : the name `LookupDoor`
  currently also exists on the OLD Governance::GovernedDoor (a repo where-query) ;
  a `query_name == "LookupDoor"` special-case would override BOTH mid-transition.
  Either scope the branch to `resolved_context == Some("Macrophage")`, or do
  Stage 5 (rip out governance) in the SAME commit as Stage 2 so there is no
  collision window. door_args : derive from the command's attribute NAMES
  (`file_path=<file_path>, …`) — accept the slightly-less-rich placeholder vs the
  old hand-written hints ; single-sourced beats pretty.
- governed_door.behaviors : per-tool LookupDoor (Bash -> Tools::ShellTool.Bash,
  … all 10), empty for control-plane ; deny-by-default. These PROVE the
  macrophage "acts like now", tool by tool. NO .fixtures.

### Stage 3 — declare `redirects_native` on the 10 door commands
- In tools.bluebook (the Tools::*.* door family) : Bash, Edit (FileTool.Edit),
  Write (FileTool.Update), Read, MultiEdit->Edit, NotebookEdit->Edit, Grep, Glob,
  WebFetch, WebSearch. Source of the 10 mappings : the OLD governance.fixtures
  (door_equivalent + door_args) — carry the native-tool name into
  `redirects_native` ; door_args now derives from attributes (accept
  attribute-name placeholders, e.g. `file_path=<file_path>`, unless an attribute
  carries a richer hint).

### Stage 4 — repoint the two hooks
- bin/governed-door-hook (PreToolUse) + bin/governed-door-complain (PostToolUse)
  read the macrophage sibling's LookupDoor (e.g.
  `Macrophage::GovernedDoor.lookup_door tool=X`) instead of
  `Governance::GovernedDoor.lookup_door`, and Record the denial on the sibling.
  Hooks otherwise UNCHANGED (same shape, same fail-modes, same HECKS_GOVERNANCE_OFF).

### Stage 5 — rip out the standalone governance domain + establishment + boot
- Delete `aggregates/framework/governance/` Policy / GovernedDoor / EnforcementAdapter
  + the establishment policies + governance.fixtures + governance.hecksagon (heki) +
  governance.behaviors (the door tests now live on the sibling).
  KEEP nothing of the door domain there.
- runtime/boot/boot.bluebook : remove the `CompleteBoot` / `BootCompleted`
  establishment wiring built in bf380359d (the lifecycle's completing ->
  studio_starting via CompleteBoot, the StartStudio-on-BootCompleted). Boot no
  longer needs to fire establishment — there is none.
- Remove the Propose->Permit->Activate cascade behaviors test (03f14e701).

## What STAYS (do not touch)
- RBAC Layer-2 (`Role`/`Agent` in aggregates/framework/agent/, feda0f32b) —
  separate concern (who-may-dispatch-which-command), not the channel barrier.
- `Violation` as the denial AUDIT — but it moves onto the macrophage sibling
  (the `Denial` entity), like every sibling keeps its own violation history.
- `append_unique` MutationOp (Chris: leave it for now — orphaned once Permit goes,
  but not reverted this pass).
- The parser unknown-mutation-op rejection (614c2fc4f) — fully independent, stands.

## Why this is fresh-head work
Stage 1 is a byte-precise `Command`-IR field across ~12 sites + generated shapes +
Ruby parity + goldens ; Stage 5 unwinds two prior commits and touches the live
boot. The design is locked (above) ; the execution wants a clean head and the full
gate, not a 40-turn-saturated context. Pick it up next boot and it's mechanical.
