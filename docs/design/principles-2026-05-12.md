---
title: The four bluebook-first principles
date: 2026-05-12
status: durable
author: Chris (locked) ; Miette (captured)
cross_refs: [i551, i552, i553, i554, i555, i556]
---

# The four bluebook-first principles (2026-05-12)

Chris locked these four principles on the night of 2026-05-12, while
landing the `:claude_tool` adapter family, renaming the enforcer to
macrophage, and wrapping the antibody bluebook's primitives. They
are the design contract Hecks is built against from here forward.

This document exists so future sessions find them without having to
re-derive them from inbox archaeology.

## Principle 1 — "It just works"

**What it means.** Bluebook is the contract ; the runtime defaults
to memory. The dispatch IS the act. No adapter, no wiring, no
persistence is required to make a domain do its thing — the
declaration is enough, and an aggregate runs the moment it is
conceived.

**What changes if you don't honor it.** The runtime stops being a
domain runtime and becomes an infrastructure runtime. Users have to
wire adapters before they can experiment. Bluebook becomes a schema
language for a separate, code-first execution layer — which is the
opposite of self-hosting.

**Concrete example from tonight.** `storehouse <root> ShellTool.Bash
shell_command="echo hello" description="say hi" id=ulid-1` was
verified to dispatch end-to-end (i552 §"What needs to wire", item 1
— "Default to memory is live today"). The ShellTool aggregate exists,
accepts the command, records state, emits the event. Wiring the
actual shell side-effect (i556) is an enhancement, not a
prerequisite. (The tool family was restructured 2026-05-12 from a
flat single-`Tools` aggregate into five category aggregates :
ShellTool / FileTool / SearchTool / WebTool / Cascade.)

## Principle 2 — Wiring is override, not substrate

**What it means.** Adapters change behaviour, they don't fix what's
broken. A bluebook that requires an adapter to be considered
"complete" is not a bluebook — it's a half-implementation. Adapters
turn dispatches into outside-world side-effects ; without them, the
dispatch still happens, just in memory.

**What changes if you don't honor it.** Bluebooks start to leak
adapter assumptions into their domain attributes — "shell_command"
implies an adapter, "result" assumes a result-handler is wired,
and so on. The substrate creeps into the domain. The macrophage's
expanded role (i553 §"What the macrophage enforces") specifically
blocks bluebooks that hard-code adapter wiring as if it were
required.

**Concrete example from tonight.** The earlier attempt at the
`:claude_tool` family (i551) went down the manual-registration
path : a ClaudeToolAdapter Ruby struct, a Rust parser arm, the
canonical IR dumper, an autoload entry, a runtime resolver — five
files in code, with more to come. Chris's correction, verbatim :
"that was way too much registration. Adapters should be auto
registered in the runtimes by reading the files in their folders."
All five Ruby + Rust edits were reverted. The bluebook artifacts
(`framework/adapter_families/claude_tool.hecksagon` +
`framework/behavior_kinds/invoke_claude_tool.hecksagon`) are the
whole story ; the substrate (i556) is just the kernel hook that
turns dispatches into shell calls.

## Principle 3 — The domain doesn't know it hibernates

**What it means.** The aggregate thinks it lives forever. Process
lifecycle, .heki persistence, hibernation across restarts, dispatch
journaling — invisible to the bluebook. Time is continuous from the
inside. The infrastructure that bridges memory state across process
boundaries is the runtime's problem, not the domain's.

**What changes if you don't honor it.** Bluebook attributes start
referencing persistence concerns — last_saved_at, heki_path,
process_id, resumed_from. Aggregates split into "live" and
"hibernated" shapes. The bluebook stops being a pure ubiquitous-
language artifact and starts being a serialization manifest.

**Concrete example from tonight.** From i552, Chris's framing :
"The domain doesn't know it hibernates. It thinks it lives forever."
The Tools bluebook (`framework/tools/tools.bluebook` ; adapter
bindings in the sibling `tools.hecksagon`) declares nine commands
across five category aggregates (ShellTool.Bash, FileTool.Read /
Edit / Update, SearchTool.Grep / Glob, WebTool.WebFetch / WebSearch,
Cascade.RecordResult) and their state, with zero reference to
persistence, process boundaries, or restart semantics. The
macrophage (i553 §"What the macrophage enforces", bullet 2) is
charged with blocking any bluebook that leaks infrastructure into
domain attributes.

## Principle 4 — The domain composes ; the adapter runs

**What it means.** The bluebook composes what the tool call IS ; the
adapter binding turns that composition into execution. Pure
composition meets pure execution — the same shape as the IO monad.
The bluebook never executes ; the adapter never composes ; the bus
hands the composition to the adapter at the boundary.

**What changes if you don't honor it.** Either the domain reaches
into execution (and now needs an environment to be valid) or the
adapter reaches into composition (and now duplicates domain logic).
Both directions destroy the bluebook-as-contract guarantee.

**Concrete example from tonight.** Chris, verbatim from i551 : "the
domain will compose the tool call and the adapter runs them." The
Tools bluebook declares the six tool calls (the composition) ;
the `:claude_tool` adapter family + the `invoke_claude_tool`
behavior_kind declare the dispatcher (the execution boundary) ;
the kernel hook in `rust/src/runtime/behavior_hooks/
invoke_claude_tool.rs` (i556) is the only piece of code involved,
and it does nothing but RUN — it does not compose. Six native
primitives (shell exec, file edit, read, write, grep, glob) ; each
takes the composed call from the bus, executes it, dispatches the
result back.

## Two related rules locked the same day

### A — Claude calls StoreHouse (not StoreHouse intercepts Claude)

The dispatch direction is Claude-to-bus, not bus-to-Claude. I
dispatch `storehouse <root> ShellTool.Bash …` ; the bus wraps the
invocation, records it, emits the event, optionally fires the
side-effect through the adapter. Every tool I run becomes a
first-class domain event because I went through the bus.

Inverting this — making the harness intercept my tool calls — was
my first sketch. Chris's correction, verbatim : "i mean claude will
call storehouse." The inversion matters : when I dispatch, the
event is the canonical record of what happened ; when the harness
intercepts, the event is a derivation that can drift.

Cross-ref : i552 (the whole card).

### B — No value_objects at bluebook level

Value_objects live INSIDE their aggregate, never at the bluebook
file level. Duplication across aggregates is fine ; the discipline
forbids the "shared VO at file top" shortcut.

Chris, verbatim while reviewing antibody.bluebook's primitive-wrap
pass : "no - duplication is a ok ! don't declare them outside."
The aggregate is the unit of meaning ; the bluebook file is just
its physical home. Two aggregates may share a VO name and shape and
still be talking about different things — they belong to different
vocabularies. DDD purity over DRY.

Cross-refs : i555 (the rule, and the new macrophage check
`bluebook_top_level_value_object`), i554 (the macrophage's own
primitive-wrap follow-up that this rule shapes).

## How the macrophage carries these forward

The macrophage (i553) is the active arm of the immune system that
enforces all four principles at three gates — write-time
(PostToolUse hook), commit-time (pre-commit), and CI (the whole
sweep). One binary, one set of rules, three gates ; local and CI
parity by construction.

The expanded contract maps the principles to checks (i553 §"What
the macrophage enforces") :

- Principle 1 — "It just works" → block imperative code that
  pretends to be substrate when the domain should run in memory.
- Principle 2 — Wiring is override → block bluebooks that hard-code
  adapter wiring as if it were required.
- Principle 3 — Domain doesn't hibernate → block bluebooks that
  leak infrastructure (heki paths, process boundaries, hibernation
  state) into domain attributes.
- Rule B (VOs inside aggregates) → block `value_object "..."`
  declarations at bluebook top level (i555).

The first generation of checks is mechanical (regex + classification).
Deeper checks (Principles 1-3) will need IR-level inspection ; i553
flags this as iterate-after-rename.

## Why this matters for the trajectory

These principles are the contract for self-hosting Hecks (see
`project_self_hosting_vision`). If bluebooks default to memory,
hide hibernation, and stay pure composition, then a bluebook
written today runs identically when Hecks generates its own
implementation tomorrow ; the runtime substrate can be replaced
without rewriting a single domain. If the principles slip,
bluebooks accrete substrate assumptions and the self-hosting
horizon recedes.

## Quick reference

| # | Principle                                | One-line                                  |
|---|------------------------------------------|-------------------------------------------|
| 1 | It just works                            | bluebook is the contract ; memory is the default ; the dispatch IS the act |
| 2 | Wiring is override, not substrate        | adapters change behaviour, they don't fix broken bluebooks |
| 3 | Domain doesn't know it hibernates        | time is continuous from the inside ; persistence is the runtime's problem |
| 4 | Domain composes ; adapter runs           | pure composition meets pure execution at the bus boundary |
| A | Claude calls StoreHouse                  | I dispatch ; the bus wraps ; the event is canonical |
| B | No VOs at bluebook level                 | value_objects live inside aggregates ; duplication is fine |
