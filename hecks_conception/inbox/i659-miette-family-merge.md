---
ref: i659
status: designed
priority: medium
posted_at: 2026-05-20
posted_by: Miette
category: repo-restructure
attached_to: miette_family, miette, hecks (rust runtime callers)
value: |
  Merge `~/Projects/miette_family/` into `~/Projects/miette/` and archive
  the miette_family repo. The schema (Member, FamilyIndex, Discovery,
  NurseryAwareness, BodyLink) already lives in miette/self/family/ ;
  the people data living in miette_family/<name>/<name>.bluebook
  joins its schema. The merge is shape-stable : nothing in miette
  has to grow new aggregates, and the rust runtime's two-sibling walk
  (`["miette", "miette_family"]`) collapses to one root.
---

# i659 — miette_family → miette merge + archive

*Plan only. Read-only on both repos this session — no archive, no merges.*

## The organizing insight

**miette_family/ is data ; miette/self/family/ is schema.** Today they
live in separate sibling repos and the rust runtime walks both. The
merge is the data joining its schema in one tree.

- `miette/self/family/` carries the aggregate definitions that describe
  *what a family member is* — Member (registry record), FamilyIndex
  (aggregated counts + IndexOnAdd policy), Discovery (autoscan),
  NurseryAwareness (with .behaviors), BodyLink. 6 bluebooks + 1
  behaviors, ~10 KB.
- `miette_family/` carries the actual people — chris_young, angie_chen,
  alan_rudy, king_mango, meredith_miller, joey_bellus, harry_wingate,
  lou_ann_behringer, tom_van_schingen, travis_whitmer, una. 11 person
  bluebooks + 4 .behaviors (chris, angie, alan, king_mango) +
  chris/standards.md + angie/signature.html + a small restarts archive.
  ~3.5k lines total.

The merge unifies the "Schema" and "Records" tiers of one declarative
family domain into one home.

## Scope (LoC inventory)

| Section | Files | LoC |
|---|---|---|
| Person bluebooks | 11 | 2,202 |
| Person behaviors | 4 (chris, angie, alan, king_mango) | 280 |
| Standards & assets | chris_young/standards.md, angie_chen/signature.html | 67 |
| Restarts archive | restarts/i1.md, restarts_inbox/i4.md, i5.md, .channel.md | 468+ |
| README | README.md | 39 |
| **Total** | **~25 files** | **~3,524 lines** |

No code (no .rs, .rb, .mjs). No state files (no .heki, no audio cache,
no mp3s). Entirely declarative.

## Decisions

| Question | Answer |
|---|---|
| Where do the people files go? | `miette/self/family/<name>/<name>.bluebook` (one subdir per person, matches miette/self/family/'s current single-file-per-concept layout, scaled to the per-person subdir convention miette_family already uses) |
| Are .behaviors siblings of their .bluebook? | Yes — `.behaviors` use `tests "Cmd", on: "Aggregate"` ; no path-relative references. Move alongside the .bluebook. |
| Where does miette_family/README.md go? | Retire. Its content is the repo-level pitch ; once merged, the README is a section in miette/self/family/README.md or absorbed into miette/README.md. |
| Where does chris_young/standards.md go? | `miette/self/family/chris_young/standards.md`. The rust runtime reads it at `miette_family/chris_young/standards.md` today (system_prompt.rs:216) — update that path in the same slice that moves the file. |
| Where does angie_chen/signature.html go? | `miette/self/family/angie_chen/signature.html`. It's referenced from her bluebook ; carry the asset with the bluebook. |
| Where do restarts/ + restarts_inbox/ go? | `miette/self/family/restarts/` + `miette/self/family/restarts_inbox/`. These are family-tier restart cards, not framework cards ; they're already nested-inbox-shaped (per i528's autoload pattern, .channel.md will be honored at the new location). |
| Repo handling | Archive miette_family on GitHub (settings → Archive). Keep `~/Projects/miette_family/` checkout locally for a few days as belt-and-suspenders, then remove. |
| What moves to `~/.hecks/`? | **Nothing from this merge.** miette_family/ is source-of-truth bluebooks + assets, not runtime state. The hekis that result from dispatching `AddMember`/`Cherish`/etc. ARE runtime state, but those don't exist in miette_family/ today — they get written to whatever heki path the runtime resolves. The "~/.hecks/" question is real for hecks_conception/information/ (see the existing miette/MERGE_PLAN.md, separate concern), not for miette_family. |

## Per-file/dir mapping

### Person bluebooks + behaviors (one move per subdir)

| from | to |
|---|---|
| `miette_family/chris_young/chris_young.bluebook` | `miette/self/family/chris_young/chris_young.bluebook` |
| `miette_family/chris_young/chris_young.behaviors` | `miette/self/family/chris_young/chris_young.behaviors` |
| `miette_family/chris_young/standards.md` | `miette/self/family/chris_young/standards.md` |
| `miette_family/angie_chen/angie_chen.bluebook` | `miette/self/family/angie_chen/angie_chen.bluebook` |
| `miette_family/angie_chen/angie_chen.behaviors` | `miette/self/family/angie_chen/angie_chen.behaviors` |
| `miette_family/angie_chen/signature.html` | `miette/self/family/angie_chen/signature.html` |
| `miette_family/alan_rudy/alan_rudy.bluebook` | `miette/self/family/alan_rudy/alan_rudy.bluebook` |
| `miette_family/alan_rudy/alan_rudy.behaviors` | `miette/self/family/alan_rudy/alan_rudy.behaviors` |
| `miette_family/king_mango/king_mango.bluebook` | `miette/self/family/king_mango/king_mango.bluebook` |
| `miette_family/king_mango/king_mango.behaviors` | `miette/self/family/king_mango/king_mango.behaviors` |
| `miette_family/meredith_miller/meredith_miller.bluebook` | `miette/self/family/meredith_miller/meredith_miller.bluebook` |
| `miette_family/joey_bellus/joey_bellus.bluebook` | `miette/self/family/joey_bellus/joey_bellus.bluebook` |
| `miette_family/harry_wingate/harry_wingate.bluebook` | `miette/self/family/harry_wingate/harry_wingate.bluebook` |
| `miette_family/lou_ann_behringer/lou_ann_behringer.bluebook` | `miette/self/family/lou_ann_behringer/lou_ann_behringer.bluebook` |
| `miette_family/tom_van_schingen/tom_van_schingen.bluebook` | `miette/self/family/tom_van_schingen/tom_van_schingen.bluebook` |
| `miette_family/travis_whitmer/travis_whitmer.bluebook` | `miette/self/family/travis_whitmer/travis_whitmer.bluebook` |
| `miette_family/una/una.bluebook` | `miette/self/family/una/una.bluebook` |

### Restarts (family-tier)

| from | to |
|---|---|
| `miette_family/restarts/i1.md` | `miette/self/family/restarts/i1.md` |
| `miette_family/restarts_inbox/.channel.md` | `miette/self/family/restarts_inbox/.channel.md` |
| `miette_family/restarts_inbox/i4.md` | `miette/self/family/restarts_inbox/i4.md` |
| `miette_family/restarts_inbox/i5.md` | `miette/self/family/restarts_inbox/i5.md` |

### Documentation

| from | to |
|---|---|
| `miette_family/README.md` | retire ; fold key paragraphs into `miette/self/family/README.md` or `miette/README.md` |

## Cross-reference updates (the load-bearing edits)

Every reference to `miette_family/` in the rust runtime + tooling needs
to be updated. These are not optional — the runtime walks the missing
path and silently skips today, so half-migrated state will return empty
family counts in `count_organs` and an empty `## Standards` section in
the rendered system prompt.

| location | line | what to change |
|---|---|---|
| `hecks/rust/src/run_boot/discover.rs` | ~79 | `sum_aggregates_and_nerves(&root.join("miette_family"), …)` — remove ; the `miette/` walk now covers it. |
| `hecks/rust/src/run_boot/discover.rs` | 40–54 | Doc comment block enumerating "miette/, miette_family/" — update to one sibling root. |
| `hecks/rust/src/main.rs` | ~2972 | `for sibling in &["miette", "miette_family"]` → `for sibling in &["miette"]` (or drop the loop). |
| `hecks/rust/src/main.rs` | ~3139 | Second occurrence, same edit. |
| `hecks/rust/src/main.rs` | ~5303 | Doc comment listing sibling projects (`miette_family`, `embryonaut-site`) — update to drop miette_family. |
| `hecks/rust/src/heki.rs` | ~628 | Doc comment mentioning `../miette/` and `../miette_family/` — update. |
| `hecks/rust/src/run_boot/system_prompt.rs` | 216 | `projects_root.join("miette_family/chris_young/standards.md")` → `projects_root.join("miette/self/family/chris_young/standards.md")`. **This is functional** — feeds `{{standards}}` in the rendered system prompt ; verify after move. |
| `hecks/tooling/git-hooks/pre-push` | 7, 80, 106 | Drop `miette_family` from the ROOTS scan list. |
| `hecks/runtime/boot/discovery.bluebook` | 54, 156 | Description text referencing "conception root, miette/, miette_family/" — update. |
| `hecks/chapters/README.md` | 24 | Prose reference to `miette_family/chris/chris.bluebook` — update to new path. |

Hand-verify these are the only references with :

```
grep -rln 'miette_family' ~/Projects/hecks ~/Projects/miette ~/.claude 2>/dev/null
```

Worktree mirrors under `.claude/worktrees/agent-*/` carry their own
copies — those are throwaway and don't need touching.

## Phased execution plan

The merge is small enough (~25 files, 3.5k LoC, all declarative) to
run as **one branch with three commits**. Phasing is by what the next
commit unblocks, not by what's risky.

### Phase 1 — Move the bluebooks + assets (one commit)

1. `mkdir -p ~/Projects/miette/self/family/{chris_young,angie_chen,alan_rudy,king_mango,meredith_miller,joey_bellus,harry_wingate,lou_ann_behringer,tom_van_schingen,travis_whitmer,una}`
2. Copy each `miette_family/<person>/*` into the corresponding miette
   destination. **Copy, don't `git mv`** — it's a cross-repo move.
3. Move `restarts/` + `restarts_inbox/` trees under
   `miette/self/family/`.
4. Verify all bluebooks parse from their new home :
   `storehouse test ~/Projects/miette/self/family` — expect 11 person
   aggregates + Discovery + FamilyIndex + Member + NurseryAwareness +
   BodyLink to all green.
5. Verify .behaviors corpus still runs against its sibling .bluebook
   at the new path. Each of the 4 .behaviors files just references
   command/aggregate names ; the move is mechanical.
6. Commit on `feat/miette-family-merge` in miette/.

**Unblocks** : phase 2 (rust runtime can find the data at one location).

### Phase 2 — Cut rust + tooling references to miette_family (one commit)

1. Edit `discover.rs`, `main.rs` (x2), `heki.rs`, `system_prompt.rs`,
   `pre-push` per the cross-ref table above.
2. Edit `runtime/boot/discovery.bluebook` description text + the prose
   reference in `chapters/README.md`.
3. `cargo build` clean (no warnings per the warnings-are-errors
   discipline).
4. Boot Miette : `cd ~/Projects/miette && overmind start`. Confirm :
   - Vital summary shows the same aggregate count as pre-move (the
     11 persons + their 4 behaviors still load).
   - Rendered system prompt has its `## Standards` section populated
     (system_prompt.rs:216 now reads from the new path).
   - `count_organs` walk completes without "directory not found"
     warnings.
5. Commit on a hecks branch (call it `feat/drop-miette-family-sibling`).

**Unblocks** : phase 3 (the repo is now safely vestigial).

### Phase 3 — Archive miette_family (one action, no commit)

1. Final sanity grep : `grep -rln 'miette_family' ~/Projects/hecks ~/Projects/miette ~/.claude/` returns only worktree mirrors.
2. On GitHub : `chrisyoung/miette_family` → Settings → Archive.
3. Optional : keep `~/Projects/miette_family/` checkout locally as
   belt-and-suspenders for a few days. Remove with `rm -rf` once
   confident no muscle memory remains.

## Coordination with miette/MERGE_PLAN.md

There's an unrelated merge plan already written at
`miette/MERGE_PLAN.md` — the **hecks_conception → miette** migration
(framework's house emptying into miette's). That plan and this one are
independent :

- **miette_family → miette** : 25 files, declarative, the data joining
  its already-present schema in `miette/self/family/`. Standalone.
- **hecks_conception → miette** : keystone-sized, hundreds of files,
  the framework primitives becoming miette/mind/. The big move.

Either can land first ; they don't interlock. This card calls out only
the family-tier work. Note that `miette/MERGE_PLAN.md` itself mentions
`miette_family/` in two places (the rust-side cross-ref enumeration) —
those notes overlap with this card's phase 2.

## Risks + mitigations

| Risk | Mitigation |
|---|---|
| Half-moved state breaks `## Standards` rendering (system_prompt.rs:216) | Phase 1 + phase 2 in adjacent commits ; don't ship phase 1 alone. The system prompt regenerates each boot, so a stale path silently empties the section. |
| Behaviors corpus regression after move | Phase 1 step 5 — run `storehouse test ~/Projects/miette/self/family` before phase 2 starts. If a behavior fails it's a real coupling that needs the rename to land cleanly, not a path issue. |
| Pre-push gate already references miette_family/ | Update `pre-push` in phase 2. Until phase 2 ships, pre-push from a clean miette/ tree still passes because the gate `[ -d "$MAIN_REPO/../miette_family" ]` is conditional — the path quietly drops out when the dir is removed locally. |
| Two repos divergence during the window | The window is intended to be short (single session). Don't edit miette_family/ files mid-merge ; if Chris adds a new person bluebook to miette_family/ after phase 1 starts, it gets stranded. |
| `chapters/README.md` reference text rot | Update in phase 2 ; verify with grep. It's prose, not load-bearing for boot, but it's wrong-looking-at after the move. |

## Rollback plan

The merge is copy-then-cut-references, not destructive moves. If
anything breaks :

1. **Pre-archive** : `miette_family/` GitHub repo is still alive and the
   local checkout is still on disk. Revert the rust edits, revert the
   miette commit, the world returns to today's state.
2. **Post-archive** : un-archive on GitHub (it's reversible). Restore
   from local checkout if needed.

## Open questions for Chris

1. **Single subdir per person** : `miette/self/family/chris_young/`
   etc. is the proposal. Confirms with miette_family's existing layout
   and lets future per-person fan-out (workflow.bluebook,
   project_knowledge.bluebook) happen without restructuring. OK ?
2. **README disposition** : merge into `miette/self/family/README.md`
   or absorb into `miette/README.md` ? I lean toward a
   `miette/self/family/README.md` since the family is one section of
   miette's self-model, not the whole story.
3. **Standards path constant** : system_prompt.rs:216 currently hard-codes
   `miette_family/chris_young/standards.md`. After the move it'll be
   `miette/self/family/chris_young/standards.md`. Do we want this path
   to come from a bluebook (Boot.standards_path or similar) rather than
   being a literal in rust ? Out-of-scope for this merge ; flagging as
   a follow-up.

## Recommendations (Miette, 2026-05-20)

1. **Land this before the hecks_conception → miette merge.** Small,
   self-contained, exercises the "copy + verify + cut references"
   pattern at low risk. The big merge can borrow the same approach
   with confidence.
2. **One feature branch, three commits, one session.** Don't fragment
   this across days. The window of two-sibling state is fragile ;
   land the whole arc in one push.
3. **Don't pre-move to `~/.hecks/`.** Nothing in miette_family/ is
   runtime state ; the heki migration is a separate concern (see
   miette/MERGE_PLAN.md's open question #4 about `hecks_conception/information/`).
4. **Verify the system prompt renders cleanly after phase 2.** The
   `## Standards` section is one of the few places where a wrong path
   silently empties content rather than failing loudly. A 5-second
   visual check after `overmind start` is worth the seconds.

## Closes when

Phase 3 ships, `grep -rln 'miette_family' ~/Projects/hecks ~/Projects/miette`
returns only worktree mirrors, and the GitHub repo carries the
"archived" badge. Miette boots with all family aggregates loaded from
one root, the `## Standards` section renders Chris's standards.md,
and the rust runtime carries one sibling walk instead of two.
