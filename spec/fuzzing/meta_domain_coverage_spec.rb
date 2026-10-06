require "spec_helper"
require "hecks/fuzzing"

# Fails when FEATURE_COVERAGE and the language's own grammar drift apart: a claimed feature
# the grammar dropped, or a grammar feature with no claim, exemption, guarantee or named gap.
RSpec.describe "the fuzzer's declared properties, against the language's own grammar", :aggregate_failures do
  META_DOMAIN_GRAMMAR = Hecks::Bluebook::MetaValidator.grammar_registry.bluebook("Bluebook")
  META_DOMAIN_PROPERTY_COVERAGE = Hecks::Fuzzing::Properties::FEATURE_COVERAGE
  META_DOMAIN_GUARANTEED_BY_CONSTRUCTION = Hecks::Fuzzing::Properties::GUARANTEED_BY_CONSTRUCTION

  # Every "Construct#attribute" the language declares, read off the meta-domain so new
  # attributes appear without a second edit. Entities are walked at every depth: they nest
  # (Dispatch inside Handler inside ProcessManager).
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

  # Bookkeeping no property should single out: identity/foreign-key columns, position indexes
  # pinned by spec/ir_golden_spec.rb, labels, and the meta-domain's own grammar tables.
  META_DOMAIN_STRUCTURAL_FEATURES = %w[
    Bluebook#name Bluebook#vision Bluebook#classification Bluebook#version
    Bluebook#formerly_known_as Bluebook#namespace Bluebook#normalisations Bluebook#attaches_to
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

  # Features that deserve an invariant, are not guaranteed by construction, and have no
  # property yet. Each entry names the candidate property to write.
  META_DOMAIN_KNOWN_GAPS = {
    "ReadModel#query_name"              => "the derived snake_case name is exercised by every read model ask; no property " \
                                           "names a drift between it and the declared name",
    "ReadModel#reference_name"          => "covered incidentally by aggregation_matches_recompute's own FK-join; not " \
                                           "named on its own",
    "ReadModel#reference_target"        => "same as ReadModel#reference_name",
    "ReadModel#aggregate_heads"         => "multi-head `include` composition (beyond the single reduced head " \
                                           "aggregation_matches_recompute checks) has no property of its own",
    "ReadModel#options"                 => "same class of gap as Query#options",
    "Query#needs"                       => "a generated query step always carries every argument, so the runtime's fill " \
                                           "of a needed fact (ADR 0081) is never reached by a fuzzed sequence; " \
                                           "spec/query_needs_spec.rb holds the Ruby fill and the " \
                                           "lease_clock_expired_now_from_the_clock conformance fixture holds both engines " \
                                           "to it. A property would draw a query step that omits a needed fact and compare " \
                                           "its rows with one naming the clock's reading",
    "Aggregate#projected_fields"        => "the local half of a cross-aggregate read (S12, ADR 0025) is read by " \
                                           "GuardState the same way an attribute is (ProjectionAbsent vs. " \
                                           "AttributeAbsent), but nothing populates it inside a normal command dispatch " \
                                           "— RebuildSweep is a separate, explicitly-called operation a generated fuzzer " \
                                           "sequence never runs — so there is no dispatch-shaped behavior yet for a " \
                                           "property to exercise. spec/runtime/rebuild_sweep_spec.rb covers the sweep " \
                                           "itself directly instead",
    # Found when the grammar walk began recursing past one hop; leads, not accepted gaps.
    # `Dispatch#position` is structural (see META_DOMAIN_STRUCTURAL_FEATURES).
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
    # Syntax/Keyword/Argument are the language's own grammar table, seeded once by SyntaxBoot;
    # no domain the fuzzer walks declares Syntax data, so there is no dispatch to exercise.
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

  def claimed_features = META_DOMAIN_PROPERTY_COVERAGE.values.flatten.to_set

  def exempted_features
    META_DOMAIN_STRUCTURAL_FEATURES.to_set | META_DOMAIN_GUARANTEED_BY_CONSTRUCTION.keys.to_set |
      META_DOMAIN_KNOWN_GAPS.keys.to_set
  end

  def unaccounted_message(unaccounted)
    "the language declares #{unaccounted.join(", ")} with no property claiming it, no structural " \
      "exemption, no construction guarantee, and no named META_DOMAIN_KNOWN_GAPS entry — a construct just " \
      "joined the language with nothing deciding, on purpose, whether a fuzzer property should exist for it"
  end

  # The property names `Properties.check` runs, read off the catalog it iterates because
  # calling it needs a real history.
  def checked_properties = Hecks::Fuzzing::Properties::PROPERTY_NAMES.map(&:to_sym).uniq

  it "claims, exempts, guarantees, or names a gap for every feature the language's own grammar declares" do
    unaccounted = META_DOMAIN_ALL_FEATURES - (claimed_features | exempted_features).to_a

    expect(unaccounted).to be_empty, unaccounted_message(unaccounted)
  end

  it "never lets a claim rot — every FEATURE_COVERAGE entry names a feature the live grammar still declares" do
    stale = META_DOMAIN_PROPERTY_COVERAGE.values.flatten - META_DOMAIN_ALL_FEATURES

    expect(stale).to be_empty,
                     "FEATURE_COVERAGE claims #{stale.join(", ")}, which the language's own grammar no longer " \
                     "declares — a rename or removal left a property's claim pointing at nothing"
  end

  # A gap naming a missing feature reads as accounted for while covering nothing.
  it "never lets a gap rot either — every META_DOMAIN_KNOWN_GAPS entry names a feature the live grammar still declares" do
    stale = META_DOMAIN_KNOWN_GAPS.keys - META_DOMAIN_ALL_FEATURES

    expect(stale).to be_empty,
                     "META_DOMAIN_KNOWN_GAPS names #{stale.join(", ")}, which the language's own grammar no longer " \
                     "declares — delete the entry, or fix the name it was meant to point at"
  end

  # Walks property -> claim (the other tests walk grammar -> claim).
  it "lets no property run unclaimed — every property in Properties.check appears in FEATURE_COVERAGE" do
    checked = checked_properties
    unclaimed = checked - META_DOMAIN_PROPERTY_COVERAGE.keys

    expect(checked).not_to be_empty, "could not read Properties.check's own property list from the source"
    expect(unclaimed).to be_empty, "these properties run but claim no feature: #{unclaimed.join(", ")}"
  end

  it "lets no claim outlive its property — every FEATURE_COVERAGE key still runs in Properties.check" do
    retired = META_DOMAIN_PROPERTY_COVERAGE.keys - checked_properties

    expect(retired).to be_empty, "these claim a feature but no longer run: #{retired.join(", ")}"
  end

  it "never lets a construction guarantee rot either — the same drift check, aimed at GUARANTEED_BY_CONSTRUCTION" do
    stale = META_DOMAIN_GUARANTEED_BY_CONSTRUCTION.keys - META_DOMAIN_ALL_FEATURES

    expect(stale).to be_empty,
                     "GUARANTEED_BY_CONSTRUCTION claims #{stale.join(", ")}, which the language's own grammar no longer " \
                     "declares — a rename or removal left a guarantee pointing at nothing"
  end

  it "keeps every exemption category from double-counting a feature some property already claims" do
    overlap = exempted_features & claimed_features

    expect(overlap).to be_empty,
                       "#{overlap.to_a.join(", ")} is both CLAIMED by a property and marked " \
                       "structural/guaranteed/a known gap — pick one: a real property makes the exemption a lie"
  end

  it "keeps GUARANTEED_BY_CONSTRUCTION and META_DOMAIN_KNOWN_GAPS from disagreeing about the same feature" do
    overlap = META_DOMAIN_GUARANTEED_BY_CONSTRUCTION.keys.to_set & META_DOMAIN_KNOWN_GAPS.keys.to_set

    expect(overlap).to be_empty,
                       "#{overlap.to_a.join(", ")} is claimed BOTH as guaranteed-by-construction and as an open gap — " \
                       "one of the two entries is wrong; a feature is either provably true by construction or it isn't"
  end
end
