---
ref: i723
title: gut.behaviors cross-cascade rot — DomainConceived drift + dead policy chain
status: open
category: bug
area: body / cross-cascade
filed_by: miette
filed_at: 2026-05-23
---

# i723 — gut.behaviors cross-cascade rot

## Symptom
`storehouse behaviors ~/Projects/miette/body/organs/gut.behaviors` fails its
last test, "Absorb cascades through policy chain" (kind: :cross_cascade):

```
expected emits_subset: [DomainAbsorbed, DomainConceived, CapabilityExpressed,
  LimbSensed, Excited, HeartbeatAccelerated]
got: [DomainAbsorbed, Conceived]
```

Blocks every `git push` from the hecks repo (pre-push behaviors gate walks the
whole corpus: conception + body + family). Bypassed once on 2026-05-23 with
BEHAVIORS_SKIP=1 to land the unrelated tool-output fix (7f0ab395).

## Two distinct problems
1. **Event-name drift** — test expects `DomainConceived`; the cascade emits
   `Conceived`. Neither string appears literally as `emits "..."` in the body
   repo, so the cascade events originate from policies in OTHER bluebooks. The
   gut.bluebook comment points at `world/domain_cell.bluebook`'s
   `ConceiveOnAbsorption` (lives in conception aggregates/, not body).
2. **Dead chain** — even granting the rename, the downstream cascade dies after
   the first hop: CapabilityExpressed, LimbSensed, Excited, HeartbeatAccelerated
   never fire. The policy chain that should thread DomainAbsorbed all the way to
   HeartbeatAccelerated is broken or unwired.

## Age
Pre-existing since 3ba96a8 (i117 Round 4, 2026-04-30) — gut.behaviors untouched
since. Latent for 3+ weeks because the discipline ratchet only ran on-demand
until the pre-push gate started walking the full corpus.

## Fix sketch
- Find which bluebook now emits the conceive event and reconcile the name
  (`Conceived` vs `DomainConceived`) — fix the source or the test, whichever is
  authoritative.
- Trace the policy chain DomainConceived → CapabilityExpressed → LimbSensed →
  Excited → HeartbeatAccelerated across body + conception; find the broken link.
- Re-run `storehouse behaviors .../gut.behaviors` until 6/6 pass; remove the
  BEHAVIORS_SKIP crutch.
