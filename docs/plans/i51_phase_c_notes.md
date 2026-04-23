# i51 Phase C — progress notes (PC-1, PC-1b)

Running notes on Phase C as it lands. Supplements [`i51_futamura_projections.md`](i51_futamura_projections.md) §4 Phase C and [`i51_phase_b_closeout.md`](i51_phase_b_closeout.md)'s "what's next".

## PC-1 (#357) — pilot ✅

**Goal:** bluebook-ify one Ruby specializer subclass module. Prove the pattern.

**Target:** `lib/hecks_specializer/duplicate_policy.rb` (15 LoC shell).

**Shipped:**
- `SpecializerSubclass` aggregate added to `specializer.bluebook` (7 fields)
- One fixture row for DuplicatePolicy
- `lib/hecks_specializer/meta_subclass.rb` — the meta-specializer (90 LoC Ruby)
- Golden test: `meta_specializer_produces_byte_identical_duplicate_policy_rb`
- Adapter wiring: `:specialize_meta_subclass` in `specializer.hecksagon`

**Proof:** `bin/specialize meta_subclass --diff` produces no output. The meta-specializer regenerates a file that lives in the same directory (`lib/hecks_specializer/`) as the code doing the emission. **Self-referential.** First 2nd-Futamura pilot.

**What it doesn't claim:**
- Fixed point — the meta-specializer has not yet specialized **itself**
- Base class coverage — `diagnostic_validator.rb` (148 LoC) is still hand-written
- Driver coverage — `bin/specialize` + `lib/hecks_specializer.rb` still hand-written

## PC-1b (#358) — breadth extension ✅

**Goal:** extend PC-1 to a second fixture row. Prove the pattern scales past one.

**Target:** `lib/hecks_specializer/lifecycle.rb` (15 LoC shell).

**Shipped:**
- Second `SpecializerSubclass` fixture row for Lifecycle
- `MetaSubclassLifecycle` Ruby class — subclass of `MetaSubclass` with overridden `TARGET_RS` + `row_target_name`
- Golden test: `meta_specializer_produces_byte_identical_lifecycle_rb`
- Adapter: `:specialize_meta_subclass_lifecycle`

**Proof:** same byte-identity gate, different file. 8/8 golden tests pass.

**Pattern for a third thin-subclass retirement (PC-1c and onward):**
1. Add a `SpecializerSubclass` fixture row
2. Subclass `MetaSubclass` with new `TARGET_RS` + `row_target_name`
3. `register :meta_subclass_<name>, ...`
4. Add hecksagon adapter + golden test

**One caveat:** this pattern only applies to **thin subclasses** that delegate all emission logic to `DiagnosticValidator` (i.e. duplicate_policy, lifecycle, and the not-yet-retired io). The 3 non-thin specializers (validator, validator_warnings, dump) each carry their own `emit()` body with per-target primitives. Retiring those needs a richer shape that models full class bodies — that's PC-2 scope.

## PC-2 — base class bluebook-ification (not started)

**Target:** `lib/hecks_specializer/diagnostic_validator.rb` (148 LoC).

**The hard part:** this file has real logic, not just a shell. Methods to model:
- `emit` — dispatch based on `helpers_after_rule` flag
- `emit_header`, `emit_imports` — read fixture fields, format strings
- `emit_report` + 3 `emit_report_*` methods — heredoc templates
- `emit_helper` — empty-body detection, doc-block prefixing
- `emit_rule` — leading/trailing blank flags

**Design sketch:** introduce `RubyClass` + `RubyMethod` aggregates:

- `RubyClass` — name, base_class, include_mixins, module_doc, module_path, output_rb
- `RubyMethod` — class_name, name, visibility (public/private), signature (including params), body_snippet, order

Bodies stay as `.rb.frag` snippets (same escape-hatch pattern as `.rs.frag`). Order matters for regenerating the file.

**Risk:** the method bodies here are more algorithmic than the Rust-emission bodies. Specializing them means writing Ruby templates for Ruby control flow — recursion. May be better to leave bodies embedded and just model the structure.

**Honest cost/benefit:** PC-2 doesn't reduce Ruby LoC (base class = 148 + fixtures grow). What it DOES is move method-level shape (names, signatures, ordering) to fixtures. Adding a method is a fixture edit + a snippet file. That's a real win for discoverability but modest for LoC.

## PC-3 — driver bluebook-ification (not started)

**Target:** `bin/specialize` (57 LoC) + `lib/hecks_specializer.rb` (108 LoC).

The driver is mostly boilerplate: OptParse, target registry lookup, diff mode. Small scope, low-risk retirement if PC-2's `RubyClass`/`RubyMethod` pattern works.

## PC-4 — fixed point (not started)

**Goal:** the meta-specializer regenerates its **own source**. Apply `bin/specialize meta_subclass_meta_subclass` (or equivalent) and diff against `lib/hecks_specializer/meta_subclass.rb`. Byte-identical. `binary_N == binary_(N+1)`.

**Prerequisites:** PC-2 must complete — the `RubyClass`/`RubyMethod` shape that emits base class is also what emits the meta-specializer itself.

**The theorem we'd prove:** if `mix` (the meta-specializer) can specialize itself, then `mix(mix, I) = compiler` (the 2nd Futamura projection). We have mix. We have I (any specializer subclass shell). We'd be demonstrating that mix can compile mix-like programs, which is the self-hosting step.

## Design decisions so far

**Module doc is a single string with `\n` separators, not a snippet file.** Tested in PC-1 — works fine for 4-6 line blocks. Multi-line fixture values are stable. If a future module has a doc block with backticks or special chars that need escaping, we'd revisit.

**Meta-specializer subclasses vs one-class-with-flags.** Went with subclasses (MetaSubclass + MetaSubclassLifecycle). Keeps the `bin/specialize <target>` contract stable (one target → one output). Other approaches considered:
- `bin/specialize meta_subclass --row NAME` — mutates the driver's CLI; didn't.
- `bin/specialize --all` regenerating everything — nice for regeneration but doesn't fit the byte-identity test model.

**Thin-subclass-only scope for PC-1.** Acknowledged up front. The validator/validator_warnings/dump modules with their own emit() bodies are PC-2 scope; expecting them here would conflate thin-shell retirement with full-class-body retirement.

## Open questions for PC-2

1. **How to handle heredocs in method bodies** — `emit_report_flat` is `<<~RS ... RS`. Snippet files work but add indirection. Inline in fixture with `\n` escapes is ugly past ~10 lines.
2. **Ruby include/extend mixins** — `RubyClass.include_mixins` as a comma-separated list? Array field? (Fixtures today are simple scalar strings.)
3. **Module nesting** (`module Hecks; module Specializer; ... end; end`) — emit as boilerplate in the meta-specializer or shape it as RubyModule rows?

## What's NOT on this list (yet)

- io_validator retirement — deferred as i60 pending runtime IR maturity
- Parser retirements (plan §7 step 7) — the self-referential wall; still Phase B+ future
- Phase D (3rd Futamura, multi-target compiler generator) — out of scope
- Phase E (Ruby-side specialization of `canonical_ir.rb` etc.) — optional

## Running totals as of PC-1b

| Metric | Count |
|---|---:|
| Retired Rust modules (Phase A/B) | 5 |
| Bytes regenerated from shape (Rust) | 33,881 |
| Retired Ruby modules (Phase C so far) | 2 (thin shells) |
| Bytes regenerated from shape (Ruby) | 988 |
| Golden tests | **8** (6 Rust + 2 Ruby) |
| Specializer registrations | 7 (5 Rust + 2 meta) |
| Shape aggregates | 13 (12 Phase A/B + 1 PC-1) |
| Fixtures | 161 (159 Phase A/B + 2 PC-1) |
