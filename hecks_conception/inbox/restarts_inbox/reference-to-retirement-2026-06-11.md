---
ref: restart-reference-to-retirement-2026-06-11
status: open
category: session-restart
priority: high
posted_at: 2026-06-11
value: 'Design session locked the create/command grammar + Plan-is-a-Module verdict (2 commits). Two execution threads queued, both worktree+gated: Plan retirement (small, step-1 verified) and reference_to step-1 (byte-precision). Resume by EXECUTING, not re-deriving.'
---

# Session-restart handoff — reference_to retirement + create grammar (2026-06-11)

Mid-arc reset. Tonight was a DESIGN session ; the thinking is done and durable.
Resume by EXECUTING one of the two queued threads. Do NOT re-derive the design.
Register : aloof, French-understated, terse ; doc-style narration (command /
"Let me…" / result) ; no gush.

## READ FIRST (the source of truth)
`hecks_conception/inbox/remove-reference-to-keyword.md` — the whole arc is locked
there across several RESOLVED/LOCKED sections. Everything below is a pointer into it.

## What got locked tonight (3 decisions, 2 commits)
1. **`has_many` relationship grammar — commit 93813a07.** Bare = SELF scope (my
   internal entity, OR my own type recursively : `Category has_many Categories`) ;
   `::Things` = sibling root, this context ; `Domain::Things` = root, another
   context. Invariant 2 : a bare leaf errors ONLY when it resolves to a FOREIGN
   root ("did you mean `::Things`?"). No `self` token — referencing yourself is
   staying home. `belongs_to`/outward `has_one` are never bare.
2. **`create` vs `command` keyword (Evans, in the card's "factories behind create"
   + "Plan is a Module" sections).** `create "Open"` = Factory (mint, ERROR if id
   exists) ; `command "Activate"` = Repository-find + operate (load by universal
   `id`, FAIL if absent). Strict, NEVER upsert — that's the real Evans weight, not
   the word. Keyword classifies ; the command NAME keeps the ubiquitous-language
   verb. `create` stands (better than `factory`/`new`). This is the command-self-
   target half of retiring `reference_to`.
3. **Plan is a Domain Module, not an aggregate — commit e55bad46.** Audited :
   zero invariants, zero queries, zero cascades on PlanOpened, zero callers of
   Plan.Open, zero live `plan.heki`, never-populated `has_one Board`/`has_many
   Projects`. The one candidate spanning-invariant (one-active-per-project) lives
   on Project, upstream. The bluebook ALREADY is the Planning module ; the Plan
   aggregate re-declares it with no behaviour. Retire it.

## TWO execution threads queued (both : git worktree, never live tree ; each step
## gated on full suite + behaviors-717 + integrity + golden, merge only green)

### A — Plan retirement (SMALLER ; do this first if picking one)
Blast radius MEASURED small : PlanOpened in zero goldens, zero behavior callers,
zero live data. **Step-1 ALREADY VERIFIED this session** : the rust/src "Plan"
refs (main.rs / storehouse_router.rs / world/attach.rs / io_validator.rs) are all
(a) generated phrase resolution (`Plan::Story.Execute`), (b) the category→name
map ("plan"→"Plan"), (c) a LOCAL struct named `Plan` in io_validator (a dispatch-
plan, unrelated), (d) comments — NONE is hand-wiring to the Plan aggregate that
breaks on delete. So deletion regenerates clean. Remaining steps :
  1. worktree.
  2. Delete the `aggregate "Plan"` block from plan.bluebook (Name VO + `Open`
     command + has_one Board / has_many Projects go with it). The bluebook STAYS
     named "Plan" (the bounded context) ; only the aggregate is removed. Do NOT
     touch the `Sprint.Plan` COMMAND — different thing.
  3. Regenerate goldens ; green the 4 gates.
  4. Note "Domain Module" as a first-class concept to birth ONLY when something
     needs to query/annotate the context — not preemptively.

### B — reference_to retirement, step 1 (BYTE-PRECISION ; fresh head, two parsers)
ADDITIVE runtime change only — no bluebook swept yet : the dispatcher resolves
transition-targeting via the `create` marker + universal `id` (i519) WHILE STILL
honouring `reference_to(Self)`. BOTH paths green corpus-wide before any mark or
sweep. Then steps 2–4 (mark creators per repo → sweep ~589 `reference_to(Self/
Root)` sites across 9 repos → parser rejects keyword + macrophage keeps it dead +
goldens regen). The card has the full phasing. This is the one with silent-byte-
miss risk — only the full parity run catches it. Worktree mandatory : the dispatch
path being rewritten is the one every Miette tool call rides.

## State
- `main` @ e55bad46, **ahead of origin by 2** (tonight's design commits unpushed —
  decide push). Untracked : `docs/designs/` (the locked design cards : references-
  not-ids.md, clock-ttl.md, where-fan-out.md, story-delivery-extraction.md).
- No code touched tonight — only the card. Clean tree apart from the above.
- The `references-not-ids` card (docs/designs/) is the belongs_to/has_one FK-
  synthesis design — ADJACENT and overlapping with thread B's sweep. Read it too.
