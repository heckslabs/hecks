# SESSION STATE — 2026-07-19/20 : framework substrate arc CLOSED

`main` is at `e73672bd2`, pushed, working tree clean, nothing parked.
**124/124 test binaries · hecksagon parity 400/400 · behaviors 152/152 ·
dream_content_smoke PASS · wasm32 clean · zero warnings on both targets.**

Supersedes `SESSION-STATE-2026-07-19-outbox-event-sourcing.md`, which accreted
several superseded diagnoses as the arc progressed. Read this one.

## The one-sentence problem

The runtime had no place of its own to keep its own state, so it smuggled it
into whichever app was running — and silently lost it when there was no room.

## What was actually wrong

The kernel writes three things a user's domain does not own : the event log
(`EventSourcing::Event`), the veto audit (`Governance::Violation`), and the
outbound queue (`OutboundEvent`). It reached them by asking *"is this aggregate
in MY domain?"* at seven guard sites and doing nothing when it wasn't. A minimal
boot wrote **no event log** ; a denied dispatch left **no audit row**, so
who-was-refused-what depended on which bluebooks happened to be loaded. To make
one of those slots exist, `ensure_outbox_substrate` **grafted** the outbox into
any domain with an effect port — which is why ToolShed's served page rendered a
framework module nobody wrote.

## The fix

A **framework collaborator** : a second Runtime, booted lazily, holding the
kernel's own aggregates. The kernel CALLS it instead of requiring the substrate
to be merged. All three substrates now route through it ; the graft is deleted.

- `runtime/framework_substrate.rs` — the collaborator : embedded substrate
  bluebooks, merged framework domain, declared store location, lazy accessor,
  inspection surface, door-side lookup.
- `rust/resources/framework.world` — **where** its stores live, declared with
  `dir :default` (same folder as the host's persistence), crate-owned so the
  standalone build survives. Per-project by construction : a deployed app gets
  its own storehouse, so it gets its own framework store.
- `Runtime::framework_resolves(aggregate, tail)` — the door-side half, consulted
  only AFTER the served domain fails, so a domain declaring its own aggregate of
  the same name still wins.

**`CascadeRun` deliberately did NOT move.** Its guard selects between two
*working* paths (persistent outbox vs the in-memory pump), not between working
and losing data — `mod.rs:1204` states the equivalence. It is three substrates,
not four ; the card originally said four and was corrected.

## Commits (oldest first)

```
cf274e2d7  test  end-to-end proof the event_sourced directive writes the Log
bbf680145  fix   loc-ratchet : ask the corpus by DOMAIN, not path
96d1aa66b  fix   a query result is ALWAYS a list, never a bare object
0bd076d20  feat  the pending predicate lives in the bluebook, not 3x in Rust
50b3b8db7  fix   graft the outbox only for a domain's OWN effect port
1e49c0ef4  feat  the framework collaborator (step zero)
8045e5b2e  fix   a denied dispatch always leaves an audit row
d02eb5c65  feat  the outbox moves to the collaborator ; DELETE the graft
da9625fff  fix   route out-of-process doors to the collaborator
13ce0c325  feat  declare WHERE the collaborator's stores live
77e624fa9  fix   the router read path reads where commands write
e73672bd2  refac pull two concerns out of the 4615-line runtime/mod.rs
```

## Two bugs found that were not on the plan

**The loc-ratchet was disabled and nobody knew** (`bbf680145`). Two bugs whose
effects cancelled : `bin/loc-ratchet` read its fixtures from a stale path and
fell back to hard-coded concerns, while the DECLARED fixture said
`direction: "grow"` under a comment describing a shrink gate. `grow` never
fails. The fallback was STRICTER than the declaration it stood in for, so fixing
only the path would have switched the kernel's main pressure gate OFF and
printed a green check doing it. Cured by `dump-fixtures --domain <Name>
--corpus <root>` — the script names a DOMAIN, the corpus resolves the file.

**The router read path read a different file than commands wrote**
(`77e624fa9`). `query_route` booted against the SOURCE tree while every command
door resolves through `embed::data_dir`. Use-case query steps asserting on state
a prior command wrote were reading an empty store — a silent wrong answer.
Proven by writing one Story through the command door and reading it back both
ways : `storehouse query` returned the row, the router returned `state: []`.

## Things I claimed and had to correct — read these

- **"The smoke fails because writer and reader resolve different paths."** WRONG,
  and it was in a commit message. Both processes resolved the same directory.
  The real cause was DOOR ROUTING : every in-process caller was rerouted to the
  collaborator and no out-of-process one was, so the CLI could not resolve a
  framework verb and died as `unknown command` behind the smoke's `2>/dev/null`.
- **"Net shrink arrives when the substrates move."** WRONG, three times.
  Measured : the outbox arc was **+27**, the extraction **+36**. Replacing an
  IMPLICIT mechanism with an EXPLICIT one costs lines even while deleting the
  old one. The 672 duplicated `.bluebook` lines were never counted by
  `core_runtime` anyway. **Stop predicting shrinks.**
- **"The ratchet says delta=0, so the override is unnecessary."** WRONG — the
  pre-commit hook LAGS ONE COMMIT and reports the PREVIOUS delta. I amended an
  override out and wrote a false claim into a commit message. Always measure with
  `ruby bin/loc-ratchet --base origin/main --verbose` against the working tree.

## Method notes worth keeping

- **An in-process test cannot see a cross-process bug.** The unit suite passed at
  EVERY step of the failed outbox attempt. `git diff --stat` told the story — the
  branch touched `run_host`, `runtime/mod.rs`, `reaction.rs`, `server/multi.rs`
  and no door at all.
- **Mutation-check the mutation.** One probe "passed" because its regex hit prose
  in a comment instead of the declaration line. A green mutation test proves
  nothing until you confirm the mutation landed.
- **A script that creates a file must assert the path is free.** An extraction
  script wrote to `event_log.rs` without checking and clobbered a tracked
  228-line storage primitive. Restored from HEAD ; the rewrite refuses to
  overwrite and asserts every anchor matches exactly once.
- **A search finds its own tooling.** Sweeping 1038 stores for a probe string hit
  the search script's own content, recorded through the FileTool door. That is
  the audit trail working ; the searcher has to account for being inside it.
- **Antibody exemption is FILE-LEVEL.** A marker in a file's first 30 lines is
  structurally exempt — "the marker IS the audit trail". Code extracted from an
  exempt file should carry its own marker ; a marker travels with the file, a
  commit-message exemption does not.

## In flight

A background agent is making the served walking-skeleton UI able to RUN the
queries it lists (they render in the left panel with no way to execute). It was
told not to commit and not to self-exempt. **Note for whoever picks it up :** a
query result is now ALWAYS a list (`96d1aa66b`) — a UI written against the old
single-row shape breaks on two rows.

## Next

- `inbox/CARD-framework-substrate-service.md` — the arc's card, marked RESOLVED
  with the real diagnosis.
- `runtime/mod.rs` is still **4073 lines** against a 200-line standard. The next
  clean extractions are `record_effect_outbound` and `record_cascade_run`.
- **No domain for DESIGN plans.** `Plan` models work tracking (Sprint / Story /
  Task) ; a staged implementation plan has no home, so five `inbox/PLAN-*.md`
  files are flat markdown standing in for a domain concept. Cost proven this
  session : `PLAN-outbox-as-projection-not-aggregate.md` carried a slice-3
  instruction that had been wrong for weeks and was nearly executed. A flat file
  cannot know it is stale.
- The 3-copy substrate duplication (`rust/resources/*.bluebook` vs the conception
  copies, guarded by `substrate_parity_test`) still stands. Not a LoC win — the
  win is one source of truth and deleting the guard.
