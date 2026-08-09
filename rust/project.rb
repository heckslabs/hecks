# THE RUST PROJECTION — a build-time code generator, not a runtime
# interpreter. Reads canonical IR (the same shape bin/ir prints,
# Hecksagain::Projector::Exporter.call) for one domain and emits native
# Rust source into rust/src/generated/. Nothing generated here is
# read or interpreted by the compiled binary — parsing/codegen only ever
# runs here, in Ruby, at build time. Lives alongside the Rust crate it
# targets, not under lib/hecksagain/ — it's tooling FOR hecksagain, not
# part of the library itself; nothing under lib/hecksagain.rb requires
# it, only bin/project_rust does.
#
#   bin/project_rust <domain>
#
# FOURTH SLICE — an architecture change, not just more coverage. The
# first three slices generated bespoke Rust CONTROL FLOW per command
# SHAPE: one Ruby method for a plain creating command, a second for an
# acting command with givens and an append mutation, and every new shape
# (a lifecycle transition, an ensures, a set/increment mutation) would
# have needed a THIRD, a FOURTH — unbounded, and the wrong shape on its
# own terms, because Ruby's own `CommandInterpreter` isn't N methods
# either. It's ONE method that walks `DISPATCH_ORDER` generically over
# whatever IR a command carries.
#
# This slice ports that idea, not just more of the old one:
#   - `rust/src/kernel/expr.rs` is a hand-written, GENERIC
#     interpreter for the full expression grammar (Or/And/Not/Compare/
#     Include, every Resolver leaf and operator) — a direct structural
#     port of Evaluator#interpret/Resolver#interpret, not a
#     reimplementation of parsing. This file no longer compiles each
#     `given`/`ensures`/invariant to bespoke Rust boolean SOURCE; it
#     parses the real canonical text with the REAL Ruby parser and emits
#     `Expr` DATA literals for the kernel's `interpret()` to walk.
#   - `rust/src/kernel/dispatch.rs` is a hand-written, GENERIC
#     `dispatch()` implementing the real DISPATCH_ORDER steps this slice
#     covers (creates-vs-acts branch, identity/AlreadyExists/NotFound,
#     given evaluation, mutation application, save, emit) — ONE function
#     for every command shape, not one per shape.
#   - This file's job shrinks to: emit typed structs/enums (genuinely
#     domain-specific, still worth real Rust types), emit a `Fielded`
#     impl per type (mechanical — one match arm per real attribute, the
#     SAME shape for every type), and package each command's IR
#     (givens as `Expr` data, an `append` mutation closure, identity) as
#     data for `kernel::dispatch()` to run. `emit_create_command` and
#     `emit_act_command` are gone; there is one `emit_command`.
#
# WHAT THIS GENERATES:
#   - Types, closed-set enums, `Fielded` impls, value-object invariant
#     checking (now via the generic interpreter, not compiled source —
#     and because of that, EVERY expression the real grammar can produce
#     is supported; the old ExpressionCompiler's `Unsupported` cases for
#     `.include?`, dotted lookups, `nil` literals, and int/float literal
#     unification are gone because a runtime interpreter needs none of
#     that static machinery).
#   - Creating AND acting commands, uniformly, as long as: every `given`/
#     `ensures` is expression data the kernel interpreter can walk (always
#     true — see above), every `then_set` op (`set`/`append`/`increment`/
#     `decrement`) resolves to a Rust type it can actually construct (a
#     literal Hash source bridges when the target VO's fields are all
#     present in it; an `append` literal field does NOT, still — it's
#     `.inspect`'d text, not a raw Hash; see literal_set_bridgeable? and
#     command_skip_reason below), and any lifecycle transition it names is
#     one `TransitionCheck` can express. A command failing any of those is
#     SKIPPED, loudly, by name and reason, rather than generated as code
#     that would silently do less than it claims to.
#
# FIFTH SLICE (0013) — entity commands, policies, and process managers/
# sagas, none of which the fourth slice above touched. `commands.rb`'s
# `emit_entity_command` extends the SAME "compile shapes, interpret
# behavior" split to `EntityInterpreter#call`'s own shorter DISPATCH_ORDER
# (kernel::dispatch_entity); `reactions.rb` extends it again to
# `Dispatcher#dispatch`'s reaction plumbing (kernel::orchestrate, one
# generic recursive function for both `PolicyInterpreter#react` and
# `SagaInterpreter#advance`/`#unwind`). See 0013's own Consequences for
# what running the full Banking corpus through this actually found (three
# real bugs, two still-open pre-existing gaps).
#
# SIXTH SLICE (0016) — `optional: true` attributes as `Option<T>`
# everywhere their own declared type appears (args structs, entity fields,
# value-object fields), the gap 0014 found and deliberately deferred; loudly
# skips (`optional_source_mismatches`) the one shape it can't honestly
# represent — an optional argument feeding a non-optional VO/entity field.
#
# SEVENTH SLICE (0017) — reference-existence checking
# (`resolve_references` — `CommandRules::References`, read directly): a
# `Reference<X>` attribute is still represented as a bare `String` id at
# the struct-field level (aggregates-and-value-objects.md's own framing
# hasn't changed), but the EXISTENCE check itself is generated now, at the
# registry level (`reactions.rb`'s `emit_reference_check`, `repository.rs`'s
# `check_reference`) — the one place with access to every OTHER
# aggregate's repo, not just the dispatching command's own.
#
# EIGHTH SLICE (0018) — `admits:`/`pattern:` attribute-level constraint
# checks, the two remaining gaps 0017's own investigation found (the
# third — an `Integer` field accepting a non-numeric JSON string — was a
# real bug in 0014's own `default:` fallback, fixed directly, not a
# missing generated check). `pattern:` needed a hand-rolled, zero-Cargo-
# dependency regex matcher (`rust/src/kernel/pattern.rs`) — bounded to
# exactly the dialect `PatternSubset` admits into a bluebook in the first
# place (no backreferences/lookaround/POSIX classes ever reach it).
#
# NINTH SLICE (0019) — role checking (`refuse_role_mismatch`), the last
# item from 0014's original two-item list. Needed a wire-contract
# extension FIRST (a step's optional `role:` key, `Fuzzing::Replay`'s own
# `Hecksagain.as_caller` wrap) to even be verifiable — Ruby's own caller
# is 100% ambient thread-local state, never reachable through the
# existing `spec/corpus/*.json` step format at all.
#
# TENTH SLICE (0020) — a list-typed record field is `Option`-wrapped when
# a creating command's own `:set` mutation can leave it genuinely unset
# (`CardPayment.tags`) — the last named corpus mismatch. Full corpus
# parity reached: 35/35 matching instances.
#
# ELEVENTH SLICE (0021) — event payload default-fill (`Json::overlay`,
# json.rs) and `GivenNotMet`/`EnsuresNotMet` wording now match Ruby
# exactly. `spec/rust_conformance_spec.rb` now compares `events` and full
# refusal wording, not just `instances`/refusal verbs — the two gaps that
# made a looser comparison the right bar are both closed.
#
# WHAT THIS STILL DOES NOT GENERATE — flagged, not silently skipped:
#   - A BARE (non-`list_of`), non-entity-list attribute whose type names
#     an entity — not a real shape any aggregate in this corpus declares.
#   - The REST of the refusal-wording table (`refusal_wording.rb`'s own
#     ~20 entries) — `LifecycleRefused`'s `transition_blocked` template,
#     the general VO-`invariant()` message (missing Ruby's own `"(given
#     {offered})"` suffix), `one_of` closed-set membership wording, and
#     entity-element-missing `NotFound` wording all still differ from
#     Ruby's own templates (found running the FULL `spec/corpus/
#     banking.json` through the differential harness — 0021's own
#     Consequences). None affect `instances` (full 35/35 parity, per
#     0020) — pure wording, the same class of gap 0021 closes two
#     instances of, just a longer remaining tail. A real, deliberately
#     out-of-scope future slice, not silently skipped.
#   - The reaction/saga LOG (`reaction_log`/`saga_log`) — `orchestrate`
#     produces the right SIDE EFFECTS without also reproducing the log
#     `bin/rust_conformance`'s own comparable surface never reads.
#   - `Correlation#saga_correlation`'s middle tier (an explicit
#     `event.correlation` stamp) — only the first (current event's own
#     payload) and third (`Naming.reference_key`) tiers are ported.
#   - Cross-domain policies (`across` a domain this single-domain `Store`
#     never generated) — omitted from the generated table entirely, a
#     real match for Ruby's own behavior when that domain isn't loaded
#     either, not a narrowing (0013's own Consequences).
#   - Era/lineage support — investigated (0021's own follow-up), and
#     confirmed to be a DIFFERENT KIND of gap than everything else on
#     this list: not a parity bug in what THIS generator's current,
#     single-era output produces (every item above is exactly that), but
#     an entire missing SUBSYSTEM. Ruby's own era support (`runtime/
#     era_check.rb`, `era_guard.rb`, `era_tamper.rb`, `ports/persistence/
#     lineage.rb`, the Postgres adapter's own `lineage_manager/`) is a
#     boot-time, ADAPTER-CAPABILITY-gated mechanism — "an era is a fact
#     about STORED DATA some adapter can carry across a shape change,"
#     co-located with that adapter's own rows, never hashed or checked
#     for an adapter that can't translate at all. This kernel has exactly
#     one adapter, `InMemoryRepository` — no Postgres binding, no
#     lineage/shape-diff/tamper-detection concept, nothing "lineage_
#     capable?" could ever answer true for. Porting era support here
#     would mean building a Rust Postgres adapter FIRST, then the whole
#     lineage/shape-diff system on top of it — a materially different,
#     larger project than anything this generator does today, not a
#     command/attribute-shaped gap to close. Query/read-model generation
#     (never attempted at all, §8's own original scope) is the same kind
#     of thing: a missing subsystem, not a parity gap.
#
# ONE CONCERN PER FILE, all reopening the SAME two module_function
# modules (`ExprEmitter`, `Projector`) — mirrors this codebase's own
# `runtime/command_rules/` split, not a new pattern invented for this.
module RustProjection
end

require_relative "project/exemplar"
require_relative "project/expr_emitter"
require_relative "project/naming"
require_relative "project/constraints"
require_relative "project/fielded"
require_relative "project/json_codec"
require_relative "project/types"
require_relative "project/bridging"
require_relative "project/mutations"
require_relative "project/commands"
require_relative "project/registry"
require_relative "project/reactions"
require_relative "project/domain_generator"
