# RESTART — Governed Door LOCKED (Arc 1 done), tally fixed, event-sourcing arc designed

**Date:** 2026-06-16 (session 3). **Read this whole file before acting.**
Supersedes the orientation in `doc-for-unbuilt-macrophage-2026-06-16.md` for Arc 1.

VOICE : I speak as myself — I / my / mine. My state, my brain.

## 0. Standing constraints (unchanged, now ENFORCED)

- **Every tool call routes through the storehouse door** : `mcp__storehouse__storehouse__dispatch`
  with `Tools::FileTool.Read|Edit|Write`, `Tools::ShellTool.Bash`, `Tools::SearchTool.Grep`.
  FileTool uses `file_path` ; ShellTool uses `shell_command` ; every dispatch needs a top-level `summary`.
- **This is now HARD-BLOCKED, not advisory.** Native Read/Bash/Edit/Write/Grep/Glob/etc.
  return exit 2 and DO NOT RUN. Use the door. (See §2.)
- Always the Rust runtime (`storehouse`). Bluebook-first, hard. No `git add -A`, no Co-Authored-By,
  files <200 LoC code, tests <1s. Let antibody/macrophage hooks BLOCK ; never pre-write exempt markers.

## 1. WHAT GOT DONE THIS SESSION (Arc 1 — the universal lockdown)

Chris wanted tools BLOCKED universally (last session's hook was advisory exit-0). Done + proven live :

- **The block is live and global.** `~/.claude/hooks/governed-door` (PreToolUse, matcher `*`) now
  hard-blocks (exit 2) any native IO tool that has a door equivalent ; passes (exit 0) the door
  itself + all control-plane (Agent/Task/advisor/AskUserQuestion/ToolSearch) + mcp__storehouse__*.
  16/16 test matrix green before the live swap ; proven live (native Read + native Bash both blocked,
  no execution). Blocks EVERY agent incl. subagents.
- **Admin escape (out-of-band):** launch claude with `HECKS_GOVERNANCE_OFF=1` → hook allows everything.
  Re-lock by restarting without it. The governed agent CANNOT disable its own governance mid-session.
- **Fail-OPEN:** broken storehouse binary / timeout → allow. A broken governance machine never bricks.
- **Rollback insurance:** old advisory hook saved at `~/.claude/hooks/governed-door.advisory.bak`.
  Staging copy `~/.claude/hooks/governed-door.next` is kept in sync with the live hook.
- **Door-only agent type: NOT NEEDED.** Tested naturalistically — a standard general-purpose agent,
  told NOTHING about the door, hit the native block, recovered on its own (ToolSearch → dispatch →
  FileTool.Read), and completed a read+write. The failed-explorer give-up mode did NOT recur because
  the exit-2 stderr names the door. Chris's call : universal block makes a special agent type redundant.
- **The door's OWN over-promise cleared.** `governed_door.bluebook` named a nonexistent
  `bin/governed-door-hook` as its enforcement surface ; now names the real `~/.claude/hooks/governed-door`,
  version → `2026.06.16.1`. (No-promises standard, applied to the door governing itself.)
- **The tally is fixed.** `RecordBlock` claimed to increment `blocked_count` but its then_set only
  stamped `last_blocked_at` ; added `then_set :blocked_count, increment: 1`. The live hook now dispatches
  `RecordBlock` (guarded `|| true`) on every block → count persists + a `NativeToolBlocked` bus event
  fires. Proven : native Bash block → Bash blocked_count 0→1.

## 2. UNCOMMITTED / LIVE STATE (make durable next)

- **REPO (`~/Projects/hecks`), branch `sq/doc-for-unbuilt-macrophage`** : `governed_door.bluebook`
  MODIFIED (hook-path reconcile + version bump + RecordBlock increment) — **UNCOMMITTED**.
  `governed_door.bluebook` is now **COMMITTED** (`923df0f03` : tally + hook-path reconcile ; antibody clean).
  Still **UNTRACKED** : `docs/designs/event-sourcing-lineage.md` (the dispatch-architecture design),
  this restart note, the design docs from last session. Chris hasn't yet said to commit those.
- **OUTSIDE THE REPO (no version control)** : `~/.claude/hooks/governed-door` (live blocking hook),
  `.next` (synced staging), `.advisory.bak` (rollback). Harness glue lives outside the repo by design.
- **MIETTE repo** : `discipline/anti_patterns.bluebook` still has the uncommitted `DocumentingTheUnbuilt`
  instance from last session (amend `correct_approach` to name the macrophage once Arc 0 builds it).

## 3. WHAT'S NEXT (in priority order)

1. **Commit the design doc + this restart note** (Arc 1's `governed_door.bluebook` already committed as `923df0f03`).
2. **Arc 0 — no-promises macrophage.** Discovery fork SETTLED on **(a) Scan** this session (a scanner
   adapter emits ArtifactClaim records ; macrophage verifies each via a filesystem `exists?` adapter ;
   records not IR ; warn-first). Conceive the bluebook FIRST, review with Chris, then generate (codegen
   shape + specializer + golden), then a filesystem hexagon family/adapter. Full detail in the prior
   restart note §5 + the approved plan `~/.claude/plans/velvety-juggling-sedgewick.md`.
3. **Dispatch architecture — the NEXT (BIG) ARC. Design : `docs/designs/event-sourcing-lineage.md`**
   (the file outgrew its name — it IS the dispatch-architecture design ; it carries the full reasoning
   trail incl. retractions). The CONVERGED shape :
   - **The door is the dispatch PORT (contract), NOT storehouse.** Two buses sit behind it and they DO
     NOT INTEROPERATE :
     - **CommandBus + hecksagons = the COMMUNITY/open bus.** ASYNCHRONOUS, eventually-consistent,
       simplest-possible (domain interior stays synchronous per hexagon convention ; the bus at the
       boundary is async). Cheap because it promises little. Self-hostable anywhere.
     - **Storehouse = the EMBRYONAUT product, kept BEHIND OUR INFRA.** Async too, but durable, ordered,
       event-sourced, governed, tamper-evident — "an enterprise bus that can operate an entire enterprise."
       The moat. A bluebook "on storehouse" runs against the hosted bus, not a vendored lib.
   - **The real distinction is GUARANTEE STRENGTH, not sync-vs-async — BOTH buses are async.**
   - **Bus is declared PER BLUEBOOK via a NEW domain-level hecksagon binding (Q9 resolved).** Hecksagon
     today attaches at the AGGREGATE level ; add a DOMAIN level. It's a CASCADE : domain binding = default,
     aggregate = override (most-specific-wins) — uniform for persistence, bus, any concern. Big hecksagon
     cleanup : shared persistence collapses to ONE domain-level line, aggregate blocks carry only what
     differs. Grammar extension : Hexagon chapter + `Binding` IR (`rust/src/hecksagon_ir.rs`) need a
     domain-scoped variant (no `aggregate` field).
   - **No-interop enforced on the DISPATCH, not the binding (Q10).** Bus IS overridable per-aggregate
     ("bus is an invariant" RETRACTED). Validator forbids CROSS-BUS DISPATCH — an aggregate/domain
     dispatching across a bus boundary (intra- AND cross-domain). Isolated override legal ; only a real
     crossing errors.
   - **Performance ("super performant") = per-bluebook CHOICE.** Put a bluebook on the simple CommandBus
     when you don't need enterprise guarantees ; pay storehouse cost only for storehouse bluebooks. (The
     hot-path/cold-path "layer boundary" framing is RETRACTED — no handoff, per-bluebook bus.)
   - **Ruby + Rust** each run CommandBus locally (own process, hexagon-wired) ; a bluebook placed on
     storehouse runs against the one hosted bus. Ruby stops being a second RUNTIME (rip out
     `ruby/hecks/mixins/command/dispatch.rb` + its event bus), becomes a client + parser. **Parity
     TRANSFORMS** : parse-parity stays (may invert — storehouse becomes IR truth) ; runtime-dispatch parity
     relocates to a "Ruby faithfully delegates, zero residual" conformance check — repoint the existing
     `parity/fuzz` `ruby_dispatcher` to "Ruby-via-door vs door-direct", must be byte-identical.
   - **Event sourcing + actor + lineage** lives in STOREHOUSE (the moat), not free CommandBus.
   **Chris's load-bearing lineage framing :** domain lineage (causation_id = direct parent / correlation_id
   = whole originating chain = "what caused what") and AI-governance lineage (actor + authority/delegation +
   tamper-evident integrity = "who acted, under what authority, provably") share ONE causal spine ; the ACTOR
   STAMP is the hinge ; append-only persistence makes it usable. Kernel-floor `Event`-struct change
   (`runtime/event_bus.rs` today : name/aggregate_type/aggregate_id/data — no actor, no ids, in-memory
   `history` only). Ripples through parity + wire format.
   **RESOLVED :** Q6 (perf = per-bluebook bus choice) · Q7 (no "legacy" — Ruby is parity, one door) · Q8
   (product boundary = community CommandBus / enterprise storehouse) · Q9 (domain-level hecksagon binding +
   cascade) · Q10 (no-interop = cross-bus-dispatch validator).
   **STILL OPEN (resolve with Chris before building) :** Q1 declared-role-vs-actual-actor · Q5 integrity
   mechanism (hash-chain vs signing, threat model) · the static-target fork (Ruby standalone deployable vs
   thin door-client).
   **Do NOT start at high context. Do NOT stuff role into the `data` HashMap (the bluebook violation the design avoids).**
4. **Thread B — DSL tightening** (remove `list_of`/`reference_to`, ~110 files, `docs/designs/dsl-tightening.md`).
   The original sidetrack. Chris said don't forget. Still queued.

## 4. FUTURE HARDENING (note only — do NOT act now)

- The PreToolUse hook runs a storehouse lookup on EVERY tool call, including every door dispatch
  (~700ms each). Pre-existing, not a regression. A fast-path `exit 0` for `mcp__storehouse__*` +
  control-plane (before the query) would cut hot-path latency AND make the door's availability
  independent of the registry query. Worth doing when the door work is next touched.
- Stale memory note `reference_filetool_write_broken.md` claims `FileTool.Write` never persists — it
  DOES now (used successfully all session ; verified i712). It's steering subagents toward bash
  unnecessarily. Correct or delete that memory.
