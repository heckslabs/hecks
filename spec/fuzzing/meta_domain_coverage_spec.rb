require "spec_helper"
require "hecks/fuzzing"

# The gate that automates the thing this arc exists for — "we don't do
# a good job of adding the properties when we add to the language."
# `Bluebook::MetaValidator.grammar_registry` is the language (that
# module's own header: "the language IS the source" — every real
# bluebook is judged against it, and it is loaded from the same
# `language/bluebook/*.bluebook` files whether a domain author or this
# spec asks). So every construct and attribute the language can ever
# declare is enumerable, mechanically, with no second list to keep in
# sync by hand — which is exactly the list `combination_coverage_spec.rb`
# already keeps by hand for pairwise form coverage (that file's own
# header: "Adding a property here is how a new form joins the gate").
#
# This spec closes the gap one level up: not "is this form exercised at
# all," but "does a real run's invariant exist for this feature, or was
# it left unchecked." `Properties::FEATURE_COVERAGE` is the claim —
# which property answers for which "Construct#attribute" — and this
# spec is the only thing that reads both the claim and the grammar and
# refuses to let them drift apart silently:
#
#   * a claimed feature that no longer exists in the grammar (renamed,
#     removed) fails loudly here, not by quietly protecting nothing
#   * a feature the grammar adds that nobody claims, and that isn't an
#     explicitly reasoned exemption or a named, honest KNOWN_GAP, fails
#     here too — the moment it lands, not whenever someone remembers to
#     go looking
#
# META_DOMAIN_KNOWN_GAPS is not a place to hide an unclaimed feature — it is a
# visible, itemized admission ("this needs a property, this session did
# not write one, here is why it's not a property yet"), the same
# distinction `spec/combination_coverage_spec.rb`'s own "unmet on
# purpose — and empty, which is the position to defend" makes for its
# own gate.
RSpec.describe "the fuzzer's declared properties, against the language's own grammar" do
  META_DOMAIN_GRAMMAR = Hecks::Bluebook::MetaValidator.grammar_registry.bluebook("Bluebook")
  META_DOMAIN_PROPERTY_COVERAGE = Hecks::Fuzzing::Properties::FEATURE_COVERAGE
  META_DOMAIN_GUARANTEED_BY_CONSTRUCTION = Hecks::Fuzzing::Properties::GUARANTEED_BY_CONSTRUCTION

  # Every "Construct#attribute" the language can declare, read straight
  # off the meta-domain — never re-typed, so an attribute added to
  # `language/bluebook/*.bluebook` appears here the next time this spec
  # runs, with no second edit anywhere in this file required to notice
  # it exists.
  # S17, ADR 0026 — an aggregate's own entities carry attributes too
  # (Member, nested under ValueObject), and their fields are just as real
  # a fuzzer-coverage question as any top-level aggregate's — so they are
  # walked here rather than silently dropping out of account the day
  # `entity "Member"` replaced `aggregate "Member"`.
  #
  # **Recursive, at every depth** — not just one hop down. An entity can
  # nest its own entities (`entity "Dispatch"`, inside `entity "Handler"`,
  # inside `aggregate "ProcessManager"` — lib/hecks/language/bluebook/
  # process_manager.bluebook), and walking only `agg.entities` would
  # stop at Handler, leaving Dispatch's own fields
  # (command_name/position/with_spec/compensates_command_name/
  # compensates_with_spec) outside this list entirely — never claimed,
  # never exempted, never gapped, because they were never even
  # enumerated. That is the exact one-level assumption BUG#11 broke in
  # the sequence generator's own catalog (`lib/hecks/fuzzing/
  # sequence_generator/catalog.rb`'s `each_entity_chain`, walking every
  # depth for the same reason) — this spec had the identical bug in a
  # different place. `walk_grammar_entities` is a fresh, spec-owned walk
  # over the language's own Aggregate/Entity model objects (never a
  # booted runtime's catalog — a different set of objects, so this is
  # not an import of that generator code, just the same shape of fix).
  walk_grammar_entities = lambda do |owner, &collect|
    owner.entities.each do |entity|
      collect.call(entity)
      walk_grammar_entities.call(entity, &collect)
    end
  end

  META_DOMAIN_ALL_FEATURES = META_DOMAIN_GRAMMAR.aggregates.flat_map do |agg|
    nested_features = []
    walk_grammar_entities.call(agg) do |piece|
      nested_features.concat(piece.attributes.map { |attr| "#{piece.hecks_name}##{attr.name}" })
    end
    agg.attributes.map { |attr| "#{agg.name}##{attr.name}" } + nested_features
  end.freeze

  # META_DOMAIN_STRUCTURAL_FEATURES bookkeeping — no property should ever single these out,
  # because they carry no behavior of their own to have wrong: an
  # identity/foreign-key column, a position index the language's own
  # `spec/ir_golden_spec.rb` already pins byte-for-byte, a human-facing
  # label, or the meta-domain's own grammar tables (`Vocabulary`,
  # `Syntax` — the closed sets a domain's fields point into, not a
  # feature a domain itself exercises).
  META_DOMAIN_STRUCTURAL_FEATURES = %w[
    Bluebook#name Bluebook#vision Bluebook#classification Bluebook#version
    Bluebook#formerly_known_as Bluebook#normalisations Bluebook#attaches_to
    Aggregate#bluebook Aggregate#name Aggregate#description Aggregate#provenance
    Command#aggregate Command#entity_id Command#name Command#role Command#goal Command#provenance
    Query#aggregate Query#entity_id Query#name Query#description
    ValueObject#aggregate ValueObject#name
    Entity#aggregate Entity#owner Entity#name Entity#description
    Policy#bluebook Policy#name Policy#aggregate
    ProcessManager#bluebook ProcessManager#name
    ReadModel#bluebook ReadModel#name ReadModel#description
    Vocabulary#name Syntax#name Syntax#bluebook
  ].concat(META_DOMAIN_ALL_FEATURES.select { |f| f.end_with?("#position") }).freeze

  # **Honest, itemized gaps** — a feature real enough to deserve its own
  # invariant, that this arc did not reach, and that construction alone
  # does not already guarantee (see `Properties::GUARANTEED_BY_CONSTRUCTION`
  # for the features that were checked for that category and qualified —
  # this list is what's left once those are subtracted out). Each entry
  # names the candidate property a future session should write, so
  # "unclaimed" never has to mean "unnoticed."
  META_DOMAIN_KNOWN_GAPS = {
    "Command#references"                => "reference-typed command arguments are exercised constantly (guard dereferencing) " \
                                           "but have no property of their own asking whether a dangling reference was ever " \
                                           "silently accepted",
    "Policy#on_event"                   => "which event a policy answers to is exercised by every reaction a generated " \
                                           "sequence produces, but nothing asserts a policy NEVER fires on an event it " \
                                           "doesn't declare",
    "Policy#trigger_command"            => "a policy's own target command is exercised by dispatch itself; no property " \
                                           "names a mismatch between declared trigger and what actually fired",
    # Re-examined 2026-09-11 (angle-4) — the premise this entry carried
    # ("none of the example domains declare one yet") was stale: banking
    # declares four `across` policies today (ReviewOnFreeze/
    # ReviewOnBoxSurrender -> "Compliance",
    # NotifyOnClosure/FlagKeyReturn -> "Notifications" —
    # examples/banking/bluebook/deposit_accounts.bluebook:477,573,
    # safe_deposit_boxes.bluebook:270,276), two of them the very
    # `unacknowledged_relationship`/`unknown_target_domain` pair those two
    # policies now declare as expected (`expect_undelivered: true`, checked
    # by model_check.rb in both directions). The gap itself still
    # holds — nothing in FEATURE_COVERAGE claims Policy#target_domain,
    # and no fuzzer property (as opposed to model_check's static check)
    # asks whether a generated sequence's cross-domain dispatch actually
    # resolves to the declared target — only the premise needed fixing.
    # Checked statically, not by a property: model_check.rb raises
    # stale_undelivered_expectation when a declared target is reachable,
    # and spec/model_check_spec.rb proves both directions on banking.
    "Policy#expect_undelivered"         => "a declared-undelivered across target is held by model_check.rb's static " \
                                           "stale check, but no fuzzer PROPERTY asks whether a generated sequence's " \
                                           "reaction to such a policy is actually recorded as undelivered at runtime",
    # Read by the role check, boot's ungoverned-role refusal, the
    # authorization adapter and the fuzzer's own grant steering (the
    # `actor_known` caller shape), all over real Governance boots.
    "Bluebook#provides"                 => "the declared authorization verbs drive every identified-caller role check a " \
                                           "sequence makes, but no property asks whether holds_role? through the " \
                                           "declared assignments verb agrees with the grants the sequence itself made",
    "Policy#target_domain"              => "cross-domain `across` policies exist in the corpus today (banking declares " \
                                           "four) and are exercised by model_check.rb's static cross-domain findings, but " \
                                           "no fuzzer PROPERTY over a GENERATED sequence's own dispatch asks whether " \
                                           "target_domain resolution matches what actually happened at runtime",
    "ReadModel#query_name"              => "the derived snake_case name is exercised by every read model ask; no property " \
                                           "names a drift between it and the declared name",
    "ReadModel#reference_name"          => "covered incidentally by aggregation_matches_recompute's own FK-join; not " \
                                           "named on its own",
    "ReadModel#reference_target"        => "same as ReadModel#reference_name",
    "ReadModel#aggregate_heads"         => "multi-head `include` composition (beyond the single reduced head " \
                                           "aggregation_matches_recompute checks) has no property of its own",
    "ReadModel#options"                 => "same class of gap as Query#options",
    "Aggregate#projected_fields"        => "the local half of a cross-aggregate read (S12, ADR 0025) is read by " \
                                           "GuardState the same way an attribute is (ProjectionAbsent vs. " \
                                           "AttributeAbsent), but nothing populates it inside a normal command dispatch " \
                                           "— RebuildSweep is a separate, explicitly-called operation a generated fuzzer " \
                                           "sequence never runs — so there is no dispatch-shaped behavior yet for a " \
                                           "property to exercise. spec/runtime/rebuild_sweep_spec.rb covers the sweep " \
                                           "itself directly instead",
    # Found by the depth fix on 2026-09-11 — leads, not accepted. Before
    # `walk_grammar_entities` (above) recursed past one hop, Dispatch's
    # own fields (nested two entities deep — ProcessManager -> Handler ->
    # Dispatch, lib/hecks/language/bluebook/process_manager.bluebook:187,
    # 237) never appeared in META_DOMAIN_ALL_FEATURES at all, so they
    # were never claimed, exempted, guaranteed, or gapped — not "known,
    # accepted, and named," just structurally invisible to this whole
    # spec. `Dispatch#position` needed no entry (it auto-qualifies as
    # structural — ends in `#position`, `META_DOMAIN_STRUCTURAL_FEATURES`
    # above). These four are real, itemized leads for a future session,
    # not settled gaps this session investigated and accepted — see the
    # PR body for each one's own file:line and disposition.
    "Dispatch#command_name"             => "found by the depth fix on 2026-09-11; lead, not accepted. " \
                                           "dispatch_binding_fidelity " \
                                           "(lib/hecks/fuzzing/properties/dispatch_and_mutations.rb) already " \
                                           "independently re-derives a Handler-declared dispatch's own " \
                                           "command_name/with_spec resolution against history[:saga_dispatches] — " \
                                           "real behavior, already checked — but FEATURE_COVERAGE's own " \
                                           "dispatch_binding_fidelity entry (properties.rb:78-91) still claims " \
                                           "\"Handler#dispatches\"/\"Policy#with_spec\" instead of this string, on " \
                                           "the explicit grounds that the string could not exist here before this " \
                                           "depth fix; PR-2 owns that file's code, so re-pointing the claim is a " \
                                           "follow-up, not something this entry papers over",
    "Dispatch#with_spec"                => "same situation as Dispatch#command_name, immediately above — " \
                                           "dispatch_binding_fidelity already checks the real behavior for a " \
                                           "HANDLER's own dispatch (not a derived compensation's — see " \
                                           "Dispatch#compensates_with_spec below for that gap), FEATURE_COVERAGE's " \
                                           "claim just can't name this string yet",
    "Dispatch#compensates_command_name" => "a GENUINE, UNCOVERED gap, not merely an unnamed string — " \
                                           "lib/hecks/runtime/saga_interpreter.rb's `deliver_derived_compensation` " \
                                           "(~L465) dispatches a completed `compensates` entry through its OWN " \
                                           "path, never through `deliver_saga_dispatch` (~L262), so it is never " \
                                           "pushed to `saga_dispatch_log` at all — `dispatch_binding_fidelity`'s " \
                                           "re-derivation (dispatch_and_mutations.rb) never sees a derived " \
                                           "compensation's own command_name, checked or not. Confirmed live: grep " \
                                           "`saga_dispatch_log` shows exactly one push site, inside " \
                                           "`deliver_saga_dispatch`, and `deliver_derived_compensation` only ever " \
                                           "appends to `saga_log` (`compensation: true`), never `saga_dispatch_log`",
    "Dispatch#compensates_with_spec"    => "same root cause as Dispatch#compensates_command_name, immediately " \
                                           "above — a derived compensation's own `with_spec` resolution " \
                                           "(spec.compensates.with_spec, resolved via the same `dispatch_args` call " \
                                           "`deliver_saga_dispatch` uses) is never logged anywhere a property could " \
                                           "independently re-derive it against",
    # S14, ADR 0026 — Syntax/Keyword/Argument are meta-domain-only : the
    # language's own grammar table, dispatched once at boot by
    # `SyntaxBoot` (a dedicated, internal mechanism — spec/syntax_
    # lifecycle_spec.rb and spec/syntax_conformance_spec.rb already hold
    # every row to the builders directly), never something a generated
    # fuzzer sequence exercises the way it exercises a real domain's own
    # Account/Customer dispatches. The fuzzer walks real corpus domains
    # (banking, pizzas, ...), none of which ever declares Syntax data —
    # there is no dispatch-shaped behavior here for a property to reach.
    "Syntax#keywords"                   => "META-DOMAIN-ONLY grammar table, seeded once by SyntaxBoot — no real domain " \
                                           "the fuzzer walks ever dispatches Syntax data ; " \
                                           "spec/syntax_lifecycle_spec.rb/spec/syntax_conformance_spec.rb already hold " \
                                           "every row to the builders directly",
    "Syntax#arguments"                  => "same as Syntax#keywords",
    "Keyword#word"                      => "same as Syntax#keywords, one level in",
    "Keyword#context"                   => "same as Syntax#keywords, one level in",
    "Keyword#body"                      => "same as Syntax#keywords, one level in",
    "Keyword#inner"                     => "same as Syntax#keywords, one level in",
    "Keyword#opens"                     => "same as Syntax#keywords, one level in",
    "Keyword#fills"                     => "same as Syntax#keywords, one level in",
    "Keyword#was"                       => "same as Syntax#keywords, one level in",
    "Keyword#resolves_via"              => "same as Syntax#keywords, one level in",
    "Keyword#disambiguator"             => "same as Syntax#keywords, one level in",
    "Keyword#calls"                     => "same as Syntax#keywords, one level in",
    "Argument#keyword"                  => "same as Syntax#arguments, one level in",
    "Argument#context"                  => "same as Syntax#arguments, one level in",
    "Argument#at"                       => "same as Syntax#arguments, one level in",
    "Argument#named"                    => "same as Syntax#arguments, one level in",
    "Argument#kind"                     => "same as Syntax#arguments, one level in",
    "Argument#required"                 => "same as Syntax#arguments, one level in",
    "Argument#minimum"                  => "same as Syntax#arguments, one level in",
    "Argument#fills"                    => "same as Syntax#arguments, one level in",
    "Argument#selects"                  => "same as Syntax#arguments, one level in",
    "Argument#pair_key_fills"           => "same as Syntax#arguments, one level in",
    "Argument#pair_value_fills"         => "same as Syntax#arguments, one level in",
    "Argument#pairs_shape"              => "same as Syntax#arguments, one level in",
    "Argument#variadic"                 => "same as Syntax#arguments, one level in",
    "Argument#coerce"                   => "same as Syntax#arguments, one level in",
    "Argument#blank_message"            => "same as Syntax#arguments, one level in"
  }.freeze

  it "claims, exempts, guarantees, or names a gap for every feature the language's own grammar declares" do
    claimed = META_DOMAIN_PROPERTY_COVERAGE.values.flatten.to_set
    accounted = claimed | META_DOMAIN_STRUCTURAL_FEATURES.to_set |
                META_DOMAIN_GUARANTEED_BY_CONSTRUCTION.keys.to_set | META_DOMAIN_KNOWN_GAPS.keys.to_set

    unaccounted = META_DOMAIN_ALL_FEATURES - accounted.to_a

    expect(unaccounted).to be_empty,
                           "the language declares #{unaccounted.join(', ')} with no property claiming it, no structural " \
                           "exemption, no construction guarantee, and no named META_DOMAIN_KNOWN_GAPS entry — a construct just " \
                           "joined the language with nothing deciding, on purpose, whether a fuzzer property should exist for it"
  end

  it "never lets a claim rot — every FEATURE_COVERAGE entry names a feature the live grammar still declares" do
    stale = META_DOMAIN_PROPERTY_COVERAGE.values.flatten - META_DOMAIN_ALL_FEATURES

    expect(stale).to be_empty,
                     "FEATURE_COVERAGE claims #{stale.join(', ')}, which the language's own grammar no longer " \
                     "declares — a rename or removal left a property's claim pointing at nothing"
  end

  # The third table had no rot check, and said so — `Properties`' own
  # comment on `dispatch_binding_fidelity` records the consequence: two
  # `Dispatch#*` entries sat here naming strings the grammar walk never
  # produces, so they exempted nothing and nothing noticed. A gap naming
  # a feature that no longer exists is worse than no entry at all: it
  # reads like an accounted-for hole while accounting for nothing.
  it "never lets a gap rot either — every META_DOMAIN_KNOWN_GAPS entry names a feature the live grammar still declares" do
    stale = META_DOMAIN_KNOWN_GAPS.keys - META_DOMAIN_ALL_FEATURES

    expect(stale).to be_empty,
                     "META_DOMAIN_KNOWN_GAPS names #{stale.join(', ')}, which the language's own grammar no longer " \
                     "declares — delete the entry, or fix the name it was meant to point at"
  end

  # Every property the battery runs declares what it answers for. This
  # file walks grammar -> claim; nothing walked property -> claim, so a
  # property could join `Properties.check` and never appear in
  # `FEATURE_COVERAGE` at all — which is how `commands_respect_tenant_scope`
  # and `corrections_reference_an_emitted_event` both ran for real while
  # that file's own stated discipline ("every property declares the
  # language feature it covers") quietly did not hold for them. Read off
  # the source, not by calling `check` — that needs a real history.
  it "lets no property run unclaimed — every property in Properties.check appears in FEATURE_COVERAGE" do
    source = File.read(File.join(InMemoryDomain::ROOT, "lib/hecks/fuzzing/properties.rb"))
    body = source[/def check\(history\)(.*?)\n      end/m, 1].to_s
    checked = body.scan(/([a-z_]+):/).flatten.map(&:to_sym).uniq
    unclaimed = checked - META_DOMAIN_PROPERTY_COVERAGE.keys
    retired = META_DOMAIN_PROPERTY_COVERAGE.keys - checked

    expect(checked).not_to be_empty, "could not read Properties.check's own property list from the source"
    expect(unclaimed).to be_empty, "these properties run but claim no feature: #{unclaimed.join(', ')}"
    expect(retired).to be_empty, "these claim a feature but no longer run: #{retired.join(', ')}"
  end

  it "never lets a construction guarantee rot either — the same drift check, aimed at GUARANTEED_BY_CONSTRUCTION" do
    stale = META_DOMAIN_GUARANTEED_BY_CONSTRUCTION.keys - META_DOMAIN_ALL_FEATURES

    expect(stale).to be_empty,
                     "GUARANTEED_BY_CONSTRUCTION claims #{stale.join(', ')}, which the language's own grammar no longer " \
                     "declares — a rename or removal left a guarantee pointing at nothing"
  end

  it "keeps every exemption category from double-counting a feature some property already claims" do
    claimed = META_DOMAIN_PROPERTY_COVERAGE.values.flatten.to_set
    exempted = META_DOMAIN_STRUCTURAL_FEATURES.to_set | META_DOMAIN_GUARANTEED_BY_CONSTRUCTION.keys.to_set |
               META_DOMAIN_KNOWN_GAPS.keys.to_set
    overlap = exempted & claimed

    expect(overlap).to be_empty,
                       "#{overlap.to_a.join(', ')} is both CLAIMED by a property and marked " \
                       "structural/guaranteed/a known gap — pick one: a real property makes the exemption a lie"
  end

  it "keeps GUARANTEED_BY_CONSTRUCTION and META_DOMAIN_KNOWN_GAPS from disagreeing about the same feature" do
    overlap = META_DOMAIN_GUARANTEED_BY_CONSTRUCTION.keys.to_set & META_DOMAIN_KNOWN_GAPS.keys.to_set

    expect(overlap).to be_empty,
                       "#{overlap.to_a.join(', ')} is claimed BOTH as guaranteed-by-construction and as an open gap — " \
                       "one of the two entries is wrong; a feature is either provably true by construction or it isn't"
  end
end
