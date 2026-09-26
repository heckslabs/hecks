# 09: The live banking deploy recipe

**Status:** Accepted 2026-09-26 · **Type:** grilling (HITL) · **Blocked by:** none · **Claimed by:** unclaimed
**Map:** [0064 client boundary](../0064-client-boundary-map.md)

## Question

`deploy/banking/` and the `production` environment overlay under `examples/banking/bluebook/environments/` are the recipe for a live stack. Generating it needs the overlay: the recipe borrows another org stack's network and database. Checked read-only on 2026-09-26: the stack exists, its status is `UPDATE_COMPLETE`, and it was last updated 2026-09-20. It is live, not a leftover.

Decide:

1. **Is the stack still wanted?** If not, retire it and delete the recipe.
2. **If it is, where does its recipe live?** The org platform repo, generated with `bin/project_deploy --out=`; or somewhere private.
3. **What stays in Hecks?** A neutral banking deploy example, so Hecks still ships one generic deploy example without the shared-network mode or the owner-stack names.
4. **What proves the move is safe?** Regenerated output byte-identical to the current recipe before anything is deleted from Hecks; no deploy as part of the move.

## Working recommendation (not a decision)

Keep the stack. Move the recipe and the overlay to the platform repo, verify byte-identical output first, and leave a neutral banking example in Hecks. Add the old directory to the ignore list so a stray regeneration cannot re-add it.

## Decision

Accepted by the owner on 2026-09-26. The stack stays. Its recipe and overlay move to the platform repo after regenerated output is proven byte-identical to the current recipe. Hecks keeps a neutral banking deploy example, and the old directory goes on the ignore list. No deploy is part of the move.
