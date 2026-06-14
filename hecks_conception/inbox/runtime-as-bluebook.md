# Runtime as a bluebook — generate runtime/mod.rs from a domain, not hand-maintain it

**Decision (Chris, 2026-06-14) : pursue the TRUE-bluebook path, as its own
deliberate arc — NOT a bolt-on.** Joins the self-hosting cards already
queued (`restarts_inbox/conceiver-as-bluebook-2026-06-13.md`,
`restarts_inbox/kernel-interpreter-2026-06-13.md`).

## The finding that triggered this
`rust/src/runtime/mod.rs` is **3477 lines and hand-maintained**. It is
SUPPOSED to be generated — the machinery exists (`codegen/runtime_shape/`
with 36 snippets, a `specialize runtime` target, and the golden test
`rust_specializer_produces_byte_identical_runtime_rs`). But that golden is
`#[ignore]`d (since the "hecks-rewrite runtime rewrite / Primitive::Process.Spawn
rewrite" landed directly in mod.rs), and the specializer is now badly stale :
`specialize runtime` emits 2357 lines vs the current 3477, **~1496 lines
diverged**. So the kernel file free-drifts with every hand-edit (the i735
`apply_sqlite_persistence` rework + the step-4 `boot_in_memory` additions are
the most recent examples).

This is a standing violation of bluebook-first : the most-consumed file in
the runtime is hand-written imperative Rust with its generate-gate disabled.

## Two senses of "make it bluebook" (the weak one was REJECTED)
- **Weak — re-shard (REJECTED).** Reconcile the 3477-line mod.rs back into
  the 36 `runtime_shape` snippets byte-identical + un-ignore the golden.
  Restores the no-drift gate, but the snippets are still hand-written Rust
  fragments — "generated" by byte-identity, NOT a domain. Chris : not worth
  it ; it's sharding, not bluebook.
- **Strong — Runtime as a domain (CHOSEN).** Describe the Runtime AS a
  bluebook and generate the Rust from it. The pieces that already point the
  way :
  - `command_dispatch` is already a phases-as-rows specializer (the dispatch
    pipeline as ordered Phase rows + snippet bodies) — the template for
    "pipeline as data."
  - Candidate domain shape : a `Runtime` aggregate ; the boot pipeline
    (`boot_with_data_dir` → factory materialise → policy/pm engines →
    projections → apply_sqlite/world dirs) as ordered phases ; dispatch as a
    contract ; `Value` / `RuntimeError` as value objects ; `repo_key` /
    repositories / mailboxes as declared structure.
  - This IS the self-hosting endgame (`project_self_hosting_vision`) — Hecks
    generating its own runtime from its own bluebook.

## Why it's a real arc, not a task
mod.rs is the kernel : Runtime struct + boot pipeline + dispatch surface +
Value/RuntimeError + repo_key/lookup + trigram/mailbox wiring. Lifting it to
a domain that regenerates the current behaviour byte-identical (then un-
ignoring the golden) is a multi-session effort and should be scoped
deliberately alongside the conceiver-as-bluebook / kernel-interpreter work,
not mixed into the persistence arc.

## Done-condition (eventual)
A `.bluebook` (or bluebook + hecksagon) describes the runtime ; `specialize
runtime` regenerates `rust/src/runtime/mod.rs` byte-identical from it ; the
golden is un-ignored and gates ; hand-edits to mod.rs become impossible
(they go through the domain). The same treatment then generalises to the
other `#[ignore]`d kernel goldens.
