# THE RUST PROJECTION — a build-time code generator, not a runtime
# interpreter. Reads canonical IR (the same shape bin/ir prints,
# Hecks::Projector::Exporter.call) for one domain and emits native
# Rust source into rust/src/generated/. Nothing generated here is
# read or interpreted by the compiled binary — parsing/codegen only ever
# runs here, in Ruby, at build time. Lives alongside the Rust crate it
# targets, not under lib/hecks/ — it's tooling FOR hecks, not
# part of the library itself; nothing under lib/hecks.rb requires
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
# `Hecks.as_caller` wrap) to even be verifiable — Ruby's own caller
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
# TWELFTH SLICE — THE INPUT IS JSON-SHAPED IR, NOT THE LIVE EXPORTER HASH —
# bin/project_rust round-trips every IR through `JSON.parse(JSON.generate(ir),
# symbolize_names: true)` before handing it here (see its own `json_shaped`
# header for why). So `mutation[:op]`/`mutation[:target]`/`attribute[:name]`
# arrive as Strings, not the Symbols `Attribute#to_h` and
# `Mutation#to_h` actually build. Everything below compares them in
# their String form (`m[:op].to_s == "set"`) — correct either way, and the
# only spelling a Rust-produced `ir.json` could ever hand this generator.
#
# THIRTEENTH SLICE — the refusal-wording table itself, GENERATED rather than
# hand-typed per call site: `bin/project_refusal_wording` reads `Hecks
# ::Runtime::RefusalWording::TEMPLATES` directly and writes `rust/src/
# kernel/refusal_wording.rs` (`RefusalSite`, one variant per (class, site)
# pair, all 39 entries — the full table, not just the ones a real Rust call
# site raises today). Closes every gap the ELEVENTH SLICE's own note named:
# `LifecycleRefused`'s `transition_blocked`, `one_of` closed-set membership
# (which was ALSO the wrong REFUSAL CLASS — `TypeMismatch`, not
# `InvariantViolation` — not merely the wrong wording), entity-element-
# missing `NotFound`, and `record_missing` via `Hydrate::Act` (found live,
# previously unnamed) all now render byte-for-byte against Ruby. The
# general VO-`invariant()` message is no longer a gap to close but a NEW
# table entry: `InvariantViolation`/`value_object_invariant` was promoted
# out of a hand-built string on the RUBY side too (`coercion.rb`'s own
# `Value.build`), so both engines now render it off the exact same
# declared template. `spec/corpus/rust_conformance/refusal_wording_*.json`
# — one fixture per site — proves each byte-for-byte, including a
# multi-field value object (`PersonName`) whose declaration order and
# sorted order genuinely diverge, not a case where they'd coincidentally
# agree.
#
# WHAT THIS STILL DOES NOT GENERATE — flagged, not silently skipped:
#   - A BARE (non-`list_of`), non-entity-list attribute whose type names
#     an entity — not a real shape any aggregate in this corpus declares.
#   - The reaction/saga LOG (`reaction_log`/`saga_log`) — NO LONGER TRUE.
#     `kernel::orchestrate` now builds both, record shape for record
#     shape, split into the SAME five functions Ruby's own `begin_saga`/
#     `advance_saga`/`deliver_saga_dispatch`/`unwind`/`end_saga` are
#     (orchestrate.rs's own header — a single merged pass used to
#     silently produce fewer log entries than Ruby's three independently-
#     gated methods do). `kernel::cli::run`'s own JSON output carries
#     both as `"reactions"`/`"sagas"`, matching `Registry#reaction_log`/
#     `#saga_log` exactly — `spec/rust_conformance_spec.rb` compares them
#     byte-for-byte now too, for every fixture. ONE deliberate, permanent
#     exception: Ruby's `rescue StandardError` branch (`defect: true`) has
#     no Rust equivalent and stays unported — a genuine interpreter crash
#     in Ruby is a compile error (or a real panic, left to propagate) in
#     Rust, never a runtime exception to catch and log as routine
#     (orchestrate.rs's own header has the full argument). Cross-domain
#     policy matches ALSO don't produce a `reaction_log` entry — this
#     kernel genuinely cannot know a cross-domain delivery's outcome, and
#     rust/host doesn't build an equivalent entry there either yet (a
#     real, separate, documented gap — see this file's own note on
#     cross-domain live delivery, below).
#   - `Correlation#saga_correlation`'s middle tier (an explicit
#     `event.correlation` stamp) — NO LONGER TRUE either. `orchestrate`
#     stamps every event a saga leg's own dispatch produces, exactly
#     where `Dispatcher#dispatch` does (`announced.each { (event.
#     correlation ||= {}).merge!(saga_correlation) }`); `correlation_of`
#     reads it back as tier 2, between tier 1 (the dotted payload path)
#     and tier 3 (`Naming.reference_key`). Proven directly (`orchestrate
#     .rs`'s own `#[cfg(test)]` module — the existing corpus alone never
#     needs tier 2 on its own, since its one real user, `AccountDebited`'s
#     handler reaching `:destination`, always has tier 1 available too).
#   - Cross-domain policies (`across` a domain this single-domain `Store`
#     used to leave ungenerated) — NO LONGER TRUE, since `reactions.rb`'s
#     own `emit_cross_domain_policy_table` (`CrossDomainPolicyRule`,
#     `kernel::orchestrate`'s own header): every declared policy,
#     cross-domain or not, gets a real manifest entry now
#     (`domain_generator.rb`), matched and carried out as a
#     `PendingCrossDomainReaction` for `rust/host`'s own `lambda_client.rs`
#     to deliver. Left here only as a "this used to be true" marker —
#     `bin/rust_coverage`'s own header has the fuller account of exactly
#     what is and isn't proven about the live-delivery half.
#
# CROSS-DOMAIN LIVE DELIVERY — a REAL, DELIBERATELY DEFERRED gap,
# consolidated here rather than left scattered across the three files
# that each independently touch a piece of it. What IS proven, real,
# and generated: a cross-domain policy match is represented (not
# dropped), the exact function-name/payload shape `rust/host/src/
# lambda_client.rs` computes for delivery is a direct, tested port of
# `Adapters::Lambda::Client`'s own convention, and a domain-level
# refusal from that delivery is recognized and swallowed the same way a
# same-domain reaction's refusal already is (that file's own `tests`
# module, against a hand-written mock `LambdaInvoker` — no real AWS
# involved). What is NOT proven, and cannot be from any environment this
# codebase's own test suite runs in: whether a REAL cross-Lambda invoke
# — `AwsLambdaInvoker`, `lambda_client.rs`'s own one genuinely
# unverifiable piece — actually reaches a live target Lambda end to end.
# That needs two real domains' Lambdas deployed and invocable
# simultaneously, which no CI run or local `cargo test`/`bundle exec
# rspec` environment has. Two further, smaller consequences of the same
# boundary, both real and both left open rather than papered over:
#   - No `reaction_log` entry exists for a cross-domain match, on EITHER
#     side of the split — this WASM kernel genuinely cannot know the
#     delivery's outcome (that only exists once `lambda_client.rs`
#     finishes the call, one layer up and out of this process entirely),
#     and rust/host's own dispatch path doesn't build an equivalent log
#     entry for its own successful/failed deliveries either. A real
#     divergence from Ruby's own single-process `reaction_log`, which
#     DOES contain an entry for a cross-domain match (Ruby has no Lambda
#     boundary to begin with) — `spec/rust_conformance_spec.rb`'s own
#     header documents this precisely, filtered out of that comparison
#     using Rust's own `cross_domain_reactions` output as the ground
#     truth for which policy names it declined to log.
#   - Delivery RETRY/backoff/dead-letter — NO LONGER TRUE (a real gap the
#     day this section was first written; closed since). `lambda_client
#     ::deliver_with_retry` sits above the `LambdaInvoker` trait boundary
#     `deliver` itself already respects, so it retries whatever invoker
#     is plugged in — `AwsLambdaInvoker` today, any future non-Amazon
#     implementer of the same trait — identically: `MAX_DELIVERY_
#     ATTEMPTS` short, doubling-backoff attempts, ONLY on a genuine
#     invoke fault (never on a clean `Ok(delivered: false)` domain-side
#     refusal — retrying a real business decision would not change it,
#     only waste the attempt). Exhausting every attempt still propagates
#     a visible failure of the Lambda invocation exactly as before — that
#     part of the design was correct and stays — but FIRST writes a
#     durable row (`journal::record_dead_letter`, a plain Postgres table
#     this crate already depends on regardless of deploy target, not an
#     AWS-native SQS/DLQ/EventBridge construct) so the exhausted attempt
#     survives past the one Lambda invocation that hit it. Proven end to
#     end against a real compiled `banking.wasm` (`dispatch.rs`'s own
#     `a_cross_domain_delivery_that_exhausts_every_retry_dead_letters_
#     and_still_fails_the_invocation`): the local Freeze commits, the
#     dead letter lands, and the invocation still fails visibly, all
#     three at once. What's still NOT proven, unchanged from above: an
#     actual reconciliation/replay tool reading `hecks_cross_domain_
#     dead_letters` back out — the table exists and is written to for
#     real; nothing yet consumes it. A real, separate, smaller future
#     slice if it's ever needed.
#
# ERA/LINEAGE SUPPORT — investigated (0021's own follow-up) and split
# into two genuinely different questions once `rust/host` (the deployed
# Lambda binary, hand-written, alongside but separate from THIS
# generator's own WASM-kernel target) grew a real Postgres binding of
# its own:
#   - Can a lineage-capable aggregate's CURRENT, already-translated state
#     be READ, and a new mutation WRITTEN, from Rust? YES, as of the
#     generalization below — `journal::read_lineage_head_all/_by_id`
#     (read) and `journal::append_lineage_mutation` (write, already
#     generic before this) both work for ANY aggregate `ir.json`'s own
#     `lineage.capable_aggregates` names (`Projector::Exporter.lineage`),
#     not just the one hand-written special case (`Embryonaut::Member`,
#     auth.rs) that proved the shape out first. `bin/rust_coverage`'s own
#     `lineage_aggregate` findings report this per domain, generated
#     unconditionally — the mechanism is host-level and generic, not
#     per-domain generated code, so there is no per-instance gap to check
#     the way a command/query has.
#   - Can THIS generator's own WASM kernel (`rust/src/kernel`,
#     `InMemoryRepository`-only, still true) MINT an era, DETECT shape
#     drift, or COMPILE a translation rule to SQL? NO, and this part of
#     the original finding still stands, by architecture rather than by
#     gap: `Runtime::EraGuard`/`EraTamper`/the Postgres adapter's own
#     `lineage_manager/*` all parse bluebook/translation-rule DSL source
#     at runtime, which ADR 0007 ("Rust generates code, not Ruby source")
#     rules out for any Rust target, kernel or host, permanently — not
#     something a future slice closes, the same way `Bind`/adapter
#     resolution itself never becomes a Rust concern. What makes reading
#     THROUGH that machinery possible without reimplementing any of it:
#     Ruby's own `HeadCompiler` already compiles every rename/move/
#     convert/drop/compute rule into the `<storage>_head` VIEW's own SQL
#     (`hecks_tr_*` helpers) at mint time — by the time any Rust code
#     runs a plain `SELECT` against it, translation has already happened.
#     A lineage-capable aggregate's commands are, exactly like Ruby's own
#     `CommandInterpreter` already treats them, dispatched OUTSIDE this
#     kernel's `InMemoryRepository`/flat-journal-replay path entirely —
#     never blended into it (see journal.rs's own header on why
#     overlaying a translated head state into a COLD REPLAY's starting
#     seed would create a new "AlreadyExists" false refusal, not fix
#     anything).
#
# FOURTEENTH SLICE — a NAMED/declared bluebook `query "X" do ... end` block
# now generates too, for the subset expressible as one or more field-
# comparator conditions against a single aggregate's OWN attributes
# (`rust/project/queries.rb`'s own header has the full eligibility
# argument). `read_model` (a cross-aggregate ask, `ReadModel`) is
# still the missing-subsystem gap the paragraph above describes — this
# slice doesn't touch it, and a query that itself needs order_by/limit/
# a reference hop/a type-unrecoverable literal comparator still has no
# generated row either, refused the same clean way an unrouted command
# already is.
#
# ONE CONCERN PER FILE, all reopening the SAME two module_function
# modules (`ExprEmitter`, `Projector`) — mirrors this codebase's own
# `runtime/command_rules/` split, not a new pattern invented for this.
module RustProjection
end

require_relative "project/exemplar"
require_relative "project/expr_emitter"
require_relative "project/naming"
require_relative "project/reference_specs"
require_relative "project/constraints"
require_relative "project/fielded"
require_relative "project/json_codec"
require_relative "project/types"
require_relative "project/bridging"
require_relative "project/mutations"
require_relative "project/commands"
require_relative "project/ports"
require_relative "project/registry"
require_relative "project/reactions"
require_relative "project/queries"
require_relative "project/read_models"
require_relative "project/domain_generator"
