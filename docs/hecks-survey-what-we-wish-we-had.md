# hecks survey: what it has that hecks doesn't

**Status: survey, 2026-08-17.** A thorough read of `~/Projects/hecks` (the
older, larger sibling that now depends on hecks via its Gemfile) to answer
one question: *what does it have that we wish we had — especially Storehouse?*

Every item is marked for how real it is over there. A lot of hecks is
conception-only (`hecks_conception/` bluebooks that describe intent) or is
currently broken by the cutover to our gem, and it would be a mistake to envy
vapor. Where a claim was verifiable it was verified: binaries were run,
processes listed, stores read.

## The one-paragraph framing

hecks is a sprawling *organism* — a persistent agent ("Miette") with a modelled
body, daemons, hooks, a corpus of ~156 bluebooks describing its own machinery.
hecks is the clean *core* that organism now runs on. Almost nothing we
envy is a language feature; the language here is stricter and better. What
hecks has is the **operational surface around the bus** — how you *see*
dispatches, *schedule* them, *gate* them, and let an agent *drive the whole
system through one door*. Storehouse is precisely that layer.

## Storehouse, concretely

Storehouse is three things wearing one name:

1. **A Rust binary** (`~/.local/bin/storehouse`, source in the private
   `hecks-hecksagain` fork). Verbs: `parse validate inspect tree list run
   establish repl serve conceive develop boot daemon loop clock sleep hydrate
   heki mailboxes dump-world dump-hecksagon`, plus undocumented-but-live
   `route play drive project specialize serve-socket serve-stdio run-loop merge
   verify-projection adapter-handler statusline follow actors`. Thirteen
   `storehouse loop|drive|clock` processes were running under overmind at
   survey time. Heki *writes* through the binary were retired ("to mutate
   state, use a bluebook command") — the binary enforces the door on itself.
2. **A Ruby CLI** (`hecks/hecks_runtime/bin/hecks-cli`) over *our*
   gem: `dispatch query state catalog describe list validate macrophage
   governed-door behaviors conceive-behaviors statusline`. One line of JSON per
   call. This is what the MCP shells out to.
3. **A corpus of bluebooks** in `hecks_conception/storehouse/` and
   `hecks_conception/aggregates/storehouse/`: `Dispatch` (the bus),
   `Lexicon` (index of every callable phrase), `Query` (read side),
   `CommandBus` (an app-scoped HTTP slice), `Story` (ordered steps as
   executable composition), `Primitive` (every kernel-floor dispatcher as a
   declared record) and `Gate` (inbound middleware as records).

The two runtimes have two stores and are not synced — hecks's own card i774
says so. That is not something to copy.

## What we wish we had — Storehouse, ranked

### 1. One universal MCP door, plus three zoom levels of discovery

`tooling/storehouse-mcp/` exposes ten tools: `dispatch`, `query`, `state`,
`catalog`, `describe_aggregate`, `list_aggregates`, `validate`,
`macrophage_check`, `behaviors`, `conceive_behaviors`. There is no per-command
tool. They *had* nine hand-registered `Tools.*` sugar tools (`_bash`, `_read`,
`_edit`, …) and deleted them:

> Each one re-stated a schema the bluebook already declared; that's a
> duplication of contract. The bluebook IS the contract — the MCP layer just
> projects it.

Every `dispatch`/`query`/`state` call requires a one-line `summary`, enforced by
the tool schema, so every audit row carries human intent for free.

*Ours:* a 3-tool query-IR MCP (`bin/hecks_query_ir_mcp`); the only
agent-facing dispatch is `bin/run <domain> '{"steps":[…]}'`. **Real and
running over there.**

### 2. `storehouse follow` — a live tail of every dispatch, every process

```
[2026-08-17T07:25:51Z] [Hecks Framework EventSourcing … Consolidate] dispatch … · process-manager
[…] event Consolidation.ConsolidateCompleted
[…] done ok 218ms · 3 events · process-manager
```

The same line protocol feeds an MCP resource (`storehouse://events`, a
`fs.watch` tail) and a `StorehouseEntry` domain
(`session/storehouse_log.bluebook`: `invocation_id, command, summary, outcome,
elapsed_ms, kind sync|async, parent_invocation_id, source_tag`, queries
`Recent / ByParent / BySource`). One stream, three renderings.

*Ours:* `bin/history` dumps a journal after the fact; nothing live, nothing
cross-process. **Real, verified streaming.**

### 3. Drivers — inbound clocks declared in the hecksagon, projected to a Procfile

```ruby
adapter "LogConsolidation" do
  driving on interval "5s" do |clock|
    dispatch "…::Consolidation.Consolidate", consolidation_id: "log"
  end
end
```

Schedule kinds `interval | cron | clock` (wall-clock hour segments, each firing
its own command). Out-of-process by construction — "a slow or dead clock stalls
only its own task, never the domain." The Procfile and `.overmind.env` are the
*projection* of every declared Driver, "exactly as a heki adapter's `.world`
block is the projection of its Family's Fields."

*Ours:* no inbound scheduling concept at all. hecks stubbed a
`kind: :driving_tick` for us; our DSL doesn't build it. **Real in the Rust
binary; unbuilt on the Ruby side** — and this is exactly the gap that leaves
4 of their 64 corpus roots invalid under our gem today. Building it closes
their blocker and gives us scheduling in one move.

### 4. `SourceTag` — a closed set of *who dispatched*

`process-manager | operator | hook | sidequest-agent | cascade | daemon`. "Show
me everything the process managers dispatched" is a one-line query. Our
`Caller` carries role and identity but not provenance kind. Cheap; do it.

### 5. Gates — middleware as bluebook records, not DSL

`Storehouse::Gate.Declare(name:, phase: before|after, check:, pattern:, order:)`.
`check` is a runtime verdict key (`"authorize"`, `"authenticate"`) *or any
bluebook query* — the runtime runs it read-only with the caller as `actor` and
allows iff it returns a row; unresolvable fails closed. The runtime hydrates its
before/after stack from `Gate.Active` at boot. The framing is the best part:

> Driver : Gate :: out-of-process clock : in-process check.

Family (outbound) / Driver (inbound source) / Gate (inbound wrapper) is their
"boundary triad."

*Ours:* authz is `runtime/command_rules/authorization.rb`; no way to attach a
query as a veto, no ordering, no after-phase observers. **Conceived, plus a
Rust MiddlewareStack; zero live `gated_by` binds in their corpus.**

### 6. Actor mailboxes, `poisoned` as a first-class status

`storehouse mailboxes list | show <type> <id> | poisoned`, all with `--json`
("tooling-stable") and `--fixture` (a deterministic 3-mailbox demo so the
inspection tool is exercisable with zero live state). Every aggregate instance
is an actor; a failed mailbox holds its queue and is listable in isolation.
**Real surface, 0 live mailboxes populated.** The `--fixture` idea alone is
worth copying for any inspection verb.

### 7. Event sourcing as "the one substrate", with a standing derivability gauge

`framework/event_sourcing/event_sourcing.bluebook` (642 lines). Event is both
the command (intent + inputs) and the delta; the fold applies the delta only.
Current state is "the trivial projection"; heki is reinterpreted as a
`Snapshot` cache — "never WRONG, only STALE", fold the tail forward on read.
Per-shard hash chain (one writer per shard; the merge orders shards, does not
re-chain them) with an in-file *honest limit*: detects corruption, truncation,
reordering; is not proof against deliberate rewrite.

A 60s Driver folds the complete Log and records `derivable | drifted`, deliberately
separating transient from persistent drift ("an alarm that fires on every race
is one everybody learns to ignore") and tracking `missing_rows` separately
("missing events have no oracle to compare against, unlike drift"). Cadence is
argued explicitly: "a minute of lag on a derivability alarm costs nothing; a
gauge that competes with real work for the hot path costs plenty."

*Ours:* heki/postgres journals exist but state is the truth and events are the
log; nothing continuously proves `fold(log) == state`. **Real and running**
(`LogConsolidation` visible in `follow` every ~5s).

### 8. `OutboundEvent` — a durable outbox for effect-port edges

`hexagon/outbound_event.bluebook`: `pending → claimed → delivered | failed`,
`delivery_id = event_id + adapter` (idempotent recording), and one host protocol
every adapter host shares: `discover → consume → act → dispatch → ack`. Named
as sibling to `CascadeRun` (the in-process reaction outbox). "The core NEVER
waits — non-blocking by construction, because there is no call to block on."
Retry policy is the host's, never the core's.

*Ours:* effect ports have no durable hand-off; a restart drops them.
**Bluebook real; `bin/adapter-host` unbuilt.**

### 9. Honest-refusal tools

`storehouse__behaviors` returns `{ok:false, supported:false, error:"…why…"}`
rather than ENOENT, a crash, or a silent no-op — "an explicit, structured
refusal a caller can act on." Trivial; adopt in `bin/*` and any MCP.

### 10. The two-tier bus, and the cascade attach level

Design only (`docs/designs/event-sourcing-lineage.md`): CommandBus = local,
in-memory, eventually-consistent, free; Storehouse = durable, ordered,
governed, tamper-evident, paid. Bus chosen per bluebook; **no cross-bus
dispatch** — the invariant is on the interaction, not the binding. Consequence:
a domain-level hecksagon binding as default with aggregate-level override,
most-specific-wins. That cascade alone would collapse our N repeated
`persisted_by` lines to one, with aggregate blocks carrying only what differs.

## Beyond Storehouse — worth stealing

- **`Session.RebuildContext` + a Stop-hook handoff gate.** ~15 lines of inline
  Python in their Claude settings: block the Stop event if the session ran
  >20 min and no fresh `category: session-restart` inbox card exists.
  `session-recall` regenerates working context *from durable state* (sprint,
  board, recent commits) into a file the next prompt injects, so `/clear` and
  compaction are recoverable. **Live and enforced** — the sharpest live gate
  they have. We rely entirely on the assistant memory directory.
- **Inbox card shape.** Frontmatter `value:` carrying the whole finding;
  `closed_note:` recording *what actually fixed it vs. what the card guessed*;
  mandatory `Where to look` (absolute paths) and `Verification once fixed` (a
  falsifiable command). Cards whose diagnosis was later falsified carry a
  "READ THE CORRECTION BEFORE ACTING" banner.
- **Antibody + LoC ratchet with signed exemptions.** Enforced in `commit-msg`
  (the only hook that sees the in-flight message, so the marker-carrying commit
  can authorise itself). Concerns declared as bluebook records with
  `direction ∈ shrink | hold | grow`, longest-prefix classification (a codegen
  subtree carves itself out of a shrinking parent, no exclude list), config
  read by *domain name* — "a stale path cannot fail loudly; an unresolvable
  domain name can, and does." Every exemption carries a retirement condition.
  **Live.**
- **`ProducedField`** — the *output* half of an adapter contract (`payment_ref`
  on stdout as `k=v`), conformance-tested. Our `.port` files type inputs only.
- **Family owns the `.world` schema.** `Hexagon.Verify` rejects unknown keys and
  missing required fields; `source ∈ direct | env | secret` is decided by the
  declaration form (`field :x` / `field :x, from: :env` / `secret :x`) — a
  secret's *name* may appear, its value never appears in any file.
- **Generated `.behaviors` tests from IR**, with a closed `Precondition`
  taxonomy that fails loudly on any `given` it cannot honor (their "AddTopping
  trap": `size < 10` was unhandled, so the whole command silently vanished).
  Our fuzzer is arguably stronger, but we have no per-command example suite
  generated from the model. **Authoring DSL exists; no interpreter under
  hecks — currently inert.**
- **Morphology promotion loop.** Runtime accumulates rejection pressure for
  words not in the compile-time list; at ≥3 the candidate is promoted and the
  compile-time artifact regenerated. A general recipe: static fast path,
  dynamic learning path, one direction of flow.
- **Tool-cache from transcript JSONL.** Walk `~/.claude/projects/*/*.jsonl`,
  tally `tool_use` names, inject a top-40 catalog at SessionStart, so a
  ToolSearch miss stops reading as "tool doesn't exist." ~180 lines, zero
  framework dependency.
- **Decentralised registries via dropped descriptor files** (`.channel.md`
  with `emoji / abbrev / label / ambient: true`), discovered by a depth-limited
  walk. Opt-IN visibility, with the postmortem: "opt-out fails silently and in
  the wrong direction."
- **The sidequest stop-rule.** "One verification pass, maximum. Inconclusive
  verification is a STOP, not a loop. The deliverable is the commit, not the
  proof. Never merge your own PR." Report capped at 150 words:
  What / Files / Status / Surprises.
- **Comments as incident reports.** Nearly every non-obvious line carries the
  live failure that produced it, the card ref, the alternative rejected, and —
  repeatedly — the earlier belief it falsified, retained in place.

## What we do *not* envy

- The governed door / macrophage PostToolUse hooks are **fail-open and currently
  dead**: their corpus doesn't boot under the pinned gem (`undefined method
  'interval'`), and the `redirects_native` DSL word was retired with no
  replacement, so even a clean boot yields an empty native→door map. The only
  live native-tool block is a static `permissions.deny` list.
- 200-line-file and tests-under-1s rules: prose plus bluebook only, no hook.
- Two runtimes, two stores, unsynced. Our "Ruby is the reference; everything
  else is differentially tested against it" is the healthier stance.
- The natural-language Sentence/Composition/ACL layer, corpus-as-vector-space
  archetypes (`StructuralVector` + cosine similarity), and the `.flow` language
  are all conception-only.

## If we build three

1. **A universal dispatch MCP door** — `dispatch / query / state / catalog /
   describe / validate`, required `summary`. We already have `bin/run` and the
   `Facade` to project it from; this is the agent-productivity multiplier.
2. **`follow` + `SourceTag`** — persist the dispatch stream we already emit
   (event log + caller kind), add a JSONL tail and a `bin/follow`.
3. **Drivers** — `driving on interval | cron | clock` in the hecksagon DSL,
   projected to a Makefile/Procfile target. hecks is blocked on us for exactly
   this; it closes their gap and gives us inbound scheduling at once.

## Sources

hecks paths, all under `~/Projects/hecks`: `CLAUDE.md`, `README.md`,
`hecks_conception/aggregates/storehouse/bluebook/storehouse.bluebook`,
`hecks_conception/storehouse/bluebook/{command_bus,dispatch,lexicon,query,story}.bluebook`,
`hecks_conception/aggregates/framework/{event_sourcing,hexagon,session,handler_registry,audit,agent_inbox,sidequest,tool_cache,mindstream,process_health}/bluebook/`,
`hecks_conception/aggregates/language/grammar/bluebook/{driving,hexagon,extraction,behaviors_conception,morphology}.bluebook`,
`hecks_conception/docs/{sprint12-architecture-decision.md,designs/event-sourcing-lineage.md,flows-design.md}`,
`tooling/storehouse-mcp/`, `tooling/git-hooks/`, `hecks_runtime/`,
`inbox/i768.md`–`i781.md`, `~/Projects/miette/self/settings.json` (hooks).
