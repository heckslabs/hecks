---
ref: i725
title: Regenerate command_dispatch specializer snippets for strict arg-validation
status: open
category: self-hosting / codegen
area: codegen/command_dispatch_shape
filed_by: miette
filed_at: 2026-05-23
---

# i725 — command_dispatch specializer golden is red (strict arg-validation hand-edit)

## What happened
Strict arg-validation (UnexpectedAttribute rejection) was added by hand to
`rust/src/runtime/command_dispatch.rs`. That file is **specializer-generated** —
`tests/specializer_golden_test.rs::rust_specializer_produces_byte_identical_command_dispatch_rs`
now FAILS because the committed file diverges from what the specializer emits
from `codegen/command_dispatch_shape/`. All 26 other specializer goldens pass ;
this is the only red one and it was green before the hand-edit.

## The fix — move the hand-edit into the generation source
Two snippet fragments need the change so regeneration is byte-identical:

1. **`snippets/sec_01_types_and_helpers.rs.frag`** — add the
   `reject_unexpected_attrs(cmd, attrs, self_ref, identity_key)` fn after
   `cmd_for` (verbatim section ; copy from the current hand-edited
   command_dispatch.rs).

2. **`snippets/phase_03_prepare.rs.frag`** — add the gate after the
   `self_ref = find_self_ref_res(...)` line :
   ```
   if cascade_hint.is_none() {
       let identity_key = rt.domain.aggregates[agg_idx].identified_by.clone();
       reject_unexpected_attrs(cmd_for(rt, res), &attrs, self_ref.as_deref(), identity_key.as_deref())?;
   }
   ```
   (already indented to 4 spaces — it's a dispatch_inner body fragment).

No fixtures/shape change needed — both land in existing Section/Phase rows.
After editing, run the golden ; it should pass byte-identical.

## Bigger picture (i724 / "UL for storehouse")
The dispatch contract — what's a valid arg, the strict-vs-lenient seam
(`cascade_hint.is_none()`) — is storehouse's ubiquitous language. The proper
end-state expresses arg-validation declaratively in the storehouse domain and
lets the specializer project it ; this card is the interim "keep self-hosting
green" step. The seam is shared with the explicit-cascade arc (i724).
