# Role checking, and the wire-contract extension it needed to be verifiable at all

**Status:** Accepted — implemented. `rust/src/kernel/{repository,orchestrate,cli}.rs`, `rust/project/{registry,domain_generator}.rb`, `lib/hecks/fuzzing/replay.rb`, branch `feat/rust-projection`. Closes the last item from 0014's original two-item list (reference-existence checking, closed by 0017).

## Context

`CommandRules::Authorization#refuse_role_mismatch` is Ruby's `role "SomeRole"` check — but unlike every other gap this arc has closed, it was never even reachable through the existing differential-harness contract. The caller's role in Ruby is 100% ambient, thread-local state (`Runtime::Caller.current`, bound by `Hecks.as_caller(role:) { ... }`), never an explicit argument to `dispatch`. `spec/corpus/*.json`'s step format and `Fuzzing::Replay.call` never bind a caller at all — confirmed live: `Caller.current` is structurally always `nil` during any replay, so `refuse_role_mismatch`'s own first line (`return unless caller`) always short-circuits before this gap could ever produce a real `Unauthorized` refusal to differentially compare against. Generating the Rust-side check first, without this, would have been correct-looking but genuinely untestable dead code.

## Decision

**Extend the wire contract first, generate the check second.** A step gained one new optional key, `role:` — absent from all 231 pre-existing corpus steps, so nothing already pinned changes behavior. `Fuzzing::Replay.call` (`lib/hecks/fuzzing/replay.rb`) wraps that ONE step's own `dispatch` call in `Hecks.as_caller(role: step["role"]) { ... }` when present, unwrapped otherwise. `bin/rust_conformance`'s subprocess mode needed no separate change — it already forwards the parsed `steps` array verbatim as the artifact's own stdin JSON, so a `role:` key present in a fixture reaches both sides of the differential comparison automatically.

On the Rust side, `kernel::cli.rs` reads the SAME `role:` key per step and threads it through `kernel::orchestrate` as a new `caller_role: Option<&str>` parameter — but ONLY at the outermost call. Ruby's own `Dispatcher#reenter` explicitly clears the ambient caller for system-triggered reactions (`Caller.without`) before re-entering dispatch for a policy or process-manager leg — matched here by every RECURSIVE `orchestrate(...)` call inside `orchestrate.rs` (`react_policies`, `advance_process_managers`, `compensate`) passing `None`, never the triggering step's own role. `dispatch_fn`'s function-pointer type grew the same `Option<&str>` parameter to carry it down to the generated `dispatch_by_name`.

The check itself, `check_role` (`repository.rs`, hand-written and generic — no per-domain data needed beyond two strings and a name), doubly opt-in exactly like Ruby's own: no caller bound (`caller_role: None`) → unchecked; no role the command itself declared (`command_role: None`) → unchecked. `role:` is a plain, mostly-absent string on `IR::Command` already exported on the wire — `domain_generator.rb` threads it (plus the command's own short `name:`, since Ruby's wording uses `command.hecks_name`, not the qualified verb) into the SAME `registry_commands`/`entity_commands` tables 0017 built for reference checks. Emitted in `registry.rb`'s router, right after `from_json` and before the reference checks — matching Ruby's own `DISPATCH_ORDER`: `refuse_role_mismatch` runs immediately before `resolve_references`.

## Consequences

- New CI fixture `spec/corpus/rust_conformance/role_checking.json`: a role-mismatched creating command refused before it's ever created, the same command succeeding once the caller's role matches, and a command with no declared role dispatched with no `role:` key at all (unchecked either way) — verified byte-for-byte matching on `instances`/`events`/`refusals` against both the native binary and the WASM artifact, not just the narrower `instances`+`refusals` the pinned spec itself checks.
- This is the last item from 0014's original two-item "role checking; reference-existence checking" list — both closed now.
- Full `bundle exec rspec` (1073 examples) and `bin/model_check` green.

## Rejected alternatives

- **Generating the check without extending the wire contract**, leaving it unverifiable until some future pass added the `role:` key anyway. Rejected outright — this codebase's own established discipline (every prior slice in this arc) is differential verification against the real Ruby oracle before calling a gap closed; shipping an unverifiable check would have been indistinguishable from not shipping one at all, just with false confidence attached.
- **A separate `caller_role:` top-level field on the whole script**, applying to every step uniformly. Rejected: Ruby's own semantics are per-dispatch (`Hecks.as_caller` wraps one block, restored after), and a real corpus legitimately mixes callers across steps (a `Customer`-role command followed by a `Teller`-role one) — a single script-wide role couldn't represent that.
