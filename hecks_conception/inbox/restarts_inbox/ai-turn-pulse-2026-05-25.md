---
ref: restart-ai-turn-pulse
category: session-restart
status: open
posted_at: 2026-05-25
branch: feat/ai-turn-pulse
---

# Restart — turn-pulse re-conceived as governance (story: turn-pulse)

## Where we are
Branch **feat/ai-turn-pulse**, 5 commits, NOT pushed, NOT on main. All pure bluebook, zero hand-written Rust.

- `4fa920d2` plan : rename planning->plan + `Story.Board` query (domain selects the slice ; no layout in the bluebook)
- `baee2f27` ai_turn : turn boundary — Start/Finish emit TurnStarted/TurnFinished
- `b8d5bdea` Task : track work-steps under a Story (story_ref, order, status todo->done ; AddTask/CompleteTask/Reopen ; ByStory/Open)
- `29b2ba7a` ai_session : governance channel — ReceivePrompt / EmitResponse / **Inject** (the conversation flows through it as recorded acts ; Transparency vow made structural)
- `708b9dd7` report-adapter : `render_to_markdown` behavior_kind + `report` adapter family (declared, parse-clean)

## The design (locked, with Chris)
The turn pulse is governance, not a formatter:
- **Board query** (domain) selects the work ; meaning is the data, NOT the layout.
- **report adapter** renders the board -> markdown (generic projection, terraform-projection-shaped ; no per-aggregate layout, no logic on the adapter).
- **AiSession.Inject** emits the markdown into the turn — a governed, recorded act on the bus. NOT a /tmp file ; emit directly. Markdown is one projection ; apps render it as HTML, terminal raw, the turn as additionalContext.
- **Chain** : report adapter `result_into` AiSession.Inject, triggered on `AiTurn.TurnFinished`.
- Session (existing) = lifecycle boundary (Begin/End) ; AiSession = governed conversation channel ; AiTurn = the per-turn grain. Three distinct aggregates.

## Remaining (the f4 frontier — fresh session)
1. **The render_to_markdown DISPATCHER = i557** (read `inbox/i557.md` : Phase-2 framework runtime, auto-discovery + kernel-hook registry, gated with i594). This is path (b) Chris chose : the dispatcher is GENERATED / registry-resolved, not hand-written per behavior_kind. Do NOT reframe as 'specializer emits markdown_dispatcher.rs' — i557 is the cleaner named path. The hand-written tts_dispatcher.rs is the byte-target to match.
2. **Hook wiring** (thin surface glue, like SessionStart->Session.Begin) : Stop -> `AiTurn.Finish` (+ AiSession.Inject on TurnFinished) ; UserPromptSubmit -> `AiSession.ReceivePrompt`. Retires `bin/planning-pulse.mjs`.

## turn-pulse story tasks (Plan::Task, story_ref=turn-pulse)
Board query, ai_turn, Task aggregate, ai_session, report-adapter-declared — DONE. dispatcher(i557), hook-wiring — TODO.
NOTE: seeding these task records FAILED via `heki append` (it needs a --reason ; the store wasn't created). Seed via MCP `storehouse__dispatch Plan::Task.AddTask` when resuming — that's the real path (the CLI `dispatch` needs a single file, the MCP door handles the dir).

## First moves next session
- `git push origin feat/ai-turn-pulse` (or merge per Chris).
- Read `inbox/i557.md` + `inbox/i594.md` deliberately before any specializer/runtime work.
- Seed the turn-pulse Plan::Task records via dispatch.

## FINAL design (locked with Chris, end of session)
The pulse is fully decoupled — neither domain knows the other :
- The **planning hecksagon** reacts to `AiTurn.TurnFinished` and calls `AiSession.Inject` with the rendered board. Planning references the turn EVENT (reacts) and the Inject COMMAND (calls) ; it does not know ai_session's internals, and ai_session does not know planning. The hecksagon (adapter layer) holds the cross-domain wiring.
- **Configuration goes in `plan.world`** : which query (Plan::Story.board), which trigger event (AiTurn.TurnFinished), which target command (AiSession.Inject). Not in the bluebook, not in the hecksagon body.
- **Render is a pure projection** : `rust/src/projection/board_markdown.rs` (committed) — records in, markdown out, NO heki (data arrives via the query, through the bus). Generic table + counts footer.
- **Rust should be EMITTED, not hand-written** (Chris, #5) : board_markdown.rs is the transitional byte-target ; the real move is a bluebook projection contract that the specializer emits to Rust (f4/i557 — same generation that did validators). Likewise the resolver that runs the query + render + chains to Inject : emit it, don't hand-write it.
- AiSession.Inject sets last_injection (the governed record) ; the next UserPromptSubmit surfaces AiSession's latest injection as additionalContext (replaces planning-pulse.mjs). No /tmp file.

## The frontier (next session, deliberate)
Making it RUN = either hand-write a resolver (the Rust #5 says to emit — avoid) OR land the f4/i557 emit : specializer generates the resolver+render from the bluebook+world declarations. Read i557 + i594. The projection render works today (byte-target) ; the emit is the cut.

## Session-end state (corrected — the (b) decision)
- Commit F (board_markdown.rs, the hand-written render) was DROPPED per #5 + the loc-ratchet (core_runtime is a SHRINK concern — don't grow the kernel by hand). The render is bluebook-SOURCED now : `board_markdown.bluebook` (commit a54492ed) is the contract ; the Rust is EMITTED from it by the specializer (f4/i557), not hand-written. The transitional arm was proven (test green) then removed ; recoverable from reflog as the emit byte-target.
- Branch feat/ai-turn-pulse : 6 commits, ALL BLUEBOOK, loc-ratchet clean. NOT pushed.
- Commit E (render_to_markdown behavior_kind + report adapter family) is the EARLIER KernelHook framing ; superseded by the projection contract (board_markdown.bluebook) + the planning-hecksagon-reacts-to-TurnFinished design. Reconcile/remove E next session.
- Frontier unchanged : the resolver (planning hecksagon reacts to TurnFinished -> runs Plan::Story.board through the bus -> feeds the projection -> calls AiSession.Inject) + the surface (UserPromptSubmit reads AiSession's latest injection) are to be EMITTED, not hand-written (f4/i557). Read i557 + i594 first.

## Auto-trigger SHIPPED (commit 6aca0417) — the inject fires itself
- `AiSession` policy `InjectOnTurnFinished` : on AiTurn.TurnFinished -> trigger (local) Inject. Pure bluebook, no Rust (Wake-on-SessionBegan pattern). DEMONSTRATED : `AiTurn.Finish` cascades `policy InjectOnTurnFinished -> Inject`.
- Manual inject of the REAL board also demonstrated this session (AiSession.Inject landed the 44-story pulse via the bus).
- So both halves work : the inject (real board) + the auto-trigger (bluebook). They are NOT yet joined : the policy fires Inject with a PLACEHOLDER ; feeding the real rendered board on the auto-fire is the report adapter's render execution = the f4/i557 emit frontier.

## To see it LIVE in the turn context (next session)
1. Persist AiSession : add a heki dir for it in a world file (config in world). Today the Inject is in-memory per dispatch ; the surface hook (next process) needs it persisted.
2. UserPromptSubmit hook : read AiSession.last_injection -> additionalContext (mirror the wake_review jq line). Loads at session start -> restart to take effect.
3. Real content : EITHER a transitional render in the Stop hook (board query -> markdown -> AiSession.Inject ; shell glue, works now) OR the emitted report adapter (board_markdown projection executed on TurnFinished ; the right way, f4/i557). The auto-TRIGGER is done ; this is the auto-RENDER + surface.

## The emit path (CORRECTED — grounded in i557 + the specializer)
Chris chose: emit the report adapter the right way. Grounding it:
- i557 is the REGISTRY (walk adapter_families/ + behavior_kinds/, resolve family->behavior->hook). i557 EXPLICITLY keeps the kernel hooks code-side : "the hooks themselves can't be bluebooked (they're the substrate)." So i557 does NOT emit the render. Earlier framing ("emit via i557") was wrong.
- The EMIT mechanism is the SPECIALIZER (i78 "specializer-files-as-bluebook"). rust/src/specializer/{adapter_llm,assemble,behaviors_parser,...}.rs each have `emit(repo_root) -> String` that GENERATES runtime Rust from a fixture/meta-shape. THAT is how Rust gets emitted, not hand-written.
- So the task : write `rust/src/specializer/board_markdown.rs` with `emit()` generating the render from the board_markdown.bluebook contract (Columns -> table walk). Template = adapter_llm.rs (closest : emits an adapter's Rust from fixtures). Byte-identity TARGET = the removed board_markdown.rs (recoverable from reflog : commit 8c6ead76 had it). Wire it into the specializer emit/assemble pipeline + the golden/parity check.
- This is a FOCUSED specializer build, not tail-of-marathon. The advisor + the discipline both say : don't improvise the specializer internals tired. Start fresh : read adapter_llm.rs + assemble.rs + the emit-pipeline runner, then write board_markdown's emit() to the byte-target.

## Tonight's end state (final)
7 commits on feat/ai-turn-pulse, ALL BLUEBOOK, ratchet-clean, NOT pushed :
  plan rename+Board ; ai_turn ; Task ; ai_session (+InjectOnTurnFinished policy) ; report-adapter declarations ; board_markdown.bluebook contract.
DEMONSTRATED live this session : (1) the inject — AiSession.Inject landed the real 44-story board pulse via the bus ; (2) the auto-trigger — AiTurn.Finish cascades policy InjectOnTurnFinished -> Inject (pure bluebook). NOT yet joined with real content (placeholder) ; that join = the specializer-emitted render above + the surface (persist AiSession in world + UserPromptSubmit hook + restart).

## pulse-live story ON THE BOARD (via proper dispatch) + a dispatch quirk noted
- `pulse-live` story captured via `Plan::Story.Capture` against the PLAN DOMAIN ROOT (aggregates/plan) — the right way, single proper record (state backlog, tier 3). It holds the 3 remaining links (emit / execution / surface). Board now 45 stories.
- DISPATCH QUIRK (worth a fresh look) : `Plan::Story.Capture` against the WHOLE conception (hecks_conception) via the long-running MCP failed with UnknownCommand ("checked Story, no Capture") — but Capture parses, no dup Story, no stale planning/, behaviors pass, and dispatch against aggregates/plan WORKS. So it is the MCP server's STALE cached whole-conception domain (loaded at boot), not a domain bug. A fresh boot reloads it. IF it recurs after a fresh boot, it is a real combined-load command-resolution bug (two `command "Capture"` : Backlog + Story) — file a runtime card then. For now : dispatch plan commands against aggregates/plan.
