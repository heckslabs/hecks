# VALIDATOR — cross-aggregate policy reference must align by name (unaligned → validate error, never silent singleton)

**Found by tracing (subagent, 2026-07-18) how a policy's triggered command gets event data.**

## The finding
Policy→command data-passing is BY NAME (convention), load-bearing, enforced
NOWHERE, and it fails SILENTLY — it checks out the WRONG record with no error.

Proven scenario : `policy "CheckOutOnBorrow" do on "Loan.ToolBorrowed" trigger
"Tool.CheckOut" end`. It works ONLY because both `Loan.BorrowTool` and
`Tool.CheckOut` independently derive the SAME attr key `tool` from
`reference_to Tool` (= to_snake_case of the target type). The shared key `tool`
flows event.data → trigger.event_data → dispatch attrs → resolved_id.

## The exact seam (traced, code-cited)
- `parser.rs:520-525` — reference attr name = `as:`/`role:` alias ELSE
  to_snake_case(target). `reference_to Tool` → `"tool"`. This is where the
  shared key is minted, independently on both sides.
- `command_dispatch.rs:340` — `event_data = attrs.clone()` : the emitted event
  carries the FULL command attrs, so `ToolBorrowed` has `tool=<id>`.
- `mod.rs:3419` — `drain_policies` : `data = trigger.event_data.clone()` then
  overlays `with:` literals. The triggered command's attrs ARE the event's data,
  passed by name (no positional/index mapping).
- `mod.rs:3699` — `inject_refs` : `if data.contains_key(&r.name) { continue; }`.
  CheckOut's `tool` is already present from the event → preserved ; the
  Loan-id injection branch (`r.target == upstream_type`) is skipped.
- `command_dispatch.rs:265` — `resolved_id` : `attrs.get(ref_name)` is the HEAD
  of the or_else chain, so `tool` wins over the cascade's Loan hint
  (`cascade_id` is None for a cross-type cascade anyway).

## The silent bug
If `Loan.BorrowTool` declared `reference_to Tool, as: :borrowed_tool`, the event
carries `borrowed_tool`, NOT `tool`. Then in `inject_refs` (mod.rs:3699)
`data.contains_key("tool")` is false, and `r.target("Tool") == upstream("Loan")`
is false, so control falls to the SINGLETON FALLBACK (mod.rs:3717-3723) :
`data["tool"] = repo.all().first()` — an arbitrary/first Tool. That wrong id then
wins at command_dispatch.rs:265. **No error. The wrong tool is checked out.**

## The fix (validator — solve with a rule, not manual testing)
A macrophage / validator rule : a POLICY that passes event data to a
CROSS-AGGREGATE command must have the triggering command (the `on` event's
source command) and the triggered command share the reference key the triggered
command needs — else ERROR at validate time. Equivalent, narrower fix at the
seam : the SINGLETON FALLBACK (mod.rs:3717-3723) must REFUSE to fire for a
cross-aggregate reference that a triggering event was supposed to carry (a
silently-wrong default is never acceptable ; refuse loudly instead).

## Why it matters
This is exactly the silent-wrong-behavior class the macrophage exists to kill,
and it rides an UNENFORCED convention. It worked in ToolShed only because both
sides happened to say `reference_to Tool`. "Happened to" is the fragility. Also
argues for a naming-consistency convention on borrow/return (event→command)
reference pairs.

## Kernel-floor — fresh head
Touches the validator/macrophage corpus + possibly the inject_refs fallback
(mod.rs:3717). Full gates (behaviors, parity, workspace).
