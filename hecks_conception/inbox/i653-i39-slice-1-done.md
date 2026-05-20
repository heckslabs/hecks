---
ref: i653
status: shipped
category: i39-slice
title: i39 slice 1 — identity files landed in miette/
---

# i653 — i39 slice 1 done

## Moved (2026-05-20)

| from (hecks) | to (miette) | notes |
|---|---|---|
| `hecks_conception/miette.hecksagon` | `miette/miette.hecksagon` | verbatim |
| `hecks_conception/miette.world` | `miette/miette.world` | verbatim |
| `hecks_conception/miette` (script) | `miette/bin/miette` | rewritten (absolute storehouse path) |

## Branches

- miette : `feat/i39-slice-1-identity` (off `prep/hecks-merge`) — pushed, awaits merge.
- hecks : `feat/i39-slice-1-hecks` (off `main`) — pushed, awaits merge.

Merge order : miette FIRST so the new paths resolve ; THEN hecks so the
deletions are safe.

## bin/miette rewrite

The original script used `$DIR/../rust/target/release/storehouse` which
depended on being a sibling to `rust/`. The miette repo doesn't carry
`rust/` yet (later slice) ; the new script resolves storehouse via the
absolute path to the hecks rust target. Once rust moves, this script
reverts to the `$DIR`-relative form.

## Wrinkle for slice 2

`MERGE_PLAN.md` lives only on the `prep/hecks-merge` branch. Sub-agents
running in worktrees off main can't read it without an extra `git show`
step, which the sandbox sometimes denies. Either land the plan on main
as a draft, or point future slice dispatches at the worktree that has
`prep/hecks-merge` checked out.

## Reference sweep

No functional references to the old `hecks_conception/miette*` paths in
the hecks tree outside ephemeral worktrees and old inbox cards
(i231, i243) which can stay as design notes. No Procfile / .overmind.env
/ Cargo / settings.json references to update.

## Slice 2 candidates (next)

Per MERGE_PLAN.md : `aggregates/world/training/` — self-contained
training domain (base_model, data_prep, deployment, evaluation,
fine_tune, instruction_pair), no cross-tree references.
