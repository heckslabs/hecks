require "spec_helper"

# The translation chapter's Rule.Kind closed set must equal the rule
# vocabulary the DSL actually admits.
#
# The two lived apart with nothing holding them together: the grammar chapter
# declared the kinds in an invariant nobody read, and
# TranslationAggregateBuilder re-spelled the same list by hand in its
# method_missing refusal. A declaration nothing reads cannot disagree with
# anything — the same drift vocabulary_conformance_spec.rb exists to stop for
# every other closed set. This is the same gate for the translation sublanguage.
RSpec.describe "the declared translation rule kinds" do
  def self.declared_kinds
    registry = Hecks::Runtime::Registry.new
    Hecks.with_registry(registry) do
      Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
      Kernel.load(InMemoryDomain::EXTRACTION_PORT)
      Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
      Kernel.load(InMemoryDomain::PRISM_ADAPTER)
      Kernel.load(File.join(InMemoryDomain::ROOT, "lib/hecks/grammar/translation.bluebook"))
    end
    kind = registry.bluebook("Translation").aggregate("Rule").value_object("Kind")
    [kind, kind.members.map { |row| row.to_h.values.first }]
  end

  KIND_OBJECT, DECLARED_KINDS = declared_kinds

  # The builder's own rule methods, introspected rather than listed — add a
  # rule to the DSL without declaring it and this fails; declare one the DSL
  # does not implement and this fails. A rule word "admitted" now means
  # EITHER a real public method OR one `GenericDispatch` (item #13's full
  # metaprogrammed dispatch) executes off the grammar table directly —
  # `drop` moved to the second kind in slice 2 (whole-project table-
  # unification survey) and no longer shows up in `public_instance_
  # methods` at all, the same way `WordGate`'s own admissibility check
  # never counted `method_missing` itself as an answered word. `unresolved`
  # (slice 4) and `rename`/`move`/`convert`/`retype`/`compute`/`rekey`/
  # `backfill` (slice 4c) all moved to the SAME second kind, but (unlike
  # `drop`) each kept a real, directly-defined method — just renamed to
  # `*_impl` and reached through `calls:` — so every one of those names has
  # to be excluded from the direct-methods half here too, or it would show
  # up as an extra "word" of its own alongside the one GENERIC_DISPATCH.
  # handles? already adds.
  GENERIC_DISPATCH = Hecks::Bluebook::DSL::GenericDispatch
  AGGREGATE_RULES = (
    (Hecks::Bluebook::DSL::TranslationAggregateBuilder.public_instance_methods(false) -
      %i[build method_missing unresolved_impl rename_impl move_impl convert_impl retype_impl compute_impl
         rekey_impl backfill_impl]).map(&:to_s) +
      Hecks::Bluebook::MetaValidator::SyntaxBoot.call[:keywords]
        .select { |row| row[:context] == "TranslationAggregate" && row[:status] != "retired" }
        .map { |row| row[:word] }
        .select { |word| GENERIC_DISPATCH.handles?("TranslationAggregate", word) }
  ).uniq.sort.freeze

  it "declares Kind as a closed set, not an open string" do
    expect(KIND_OBJECT.closed_set?).to be(true)
    expect(DECLARED_KINDS).not_to be_empty
  end

  it "matches the rule methods TranslationAggregateBuilder admits" do
    expect(DECLARED_KINDS - %w[retired]).to match_array(AGGREGATE_RULES)
  end

  it "declares retired, the edge-level kind, which the edge builder admits" do
    expect(DECLARED_KINDS).to include("retired")
    expect(GENERIC_DISPATCH.handles?("Translation", "retired")).to be(true)
  end

  # WordGate (item #13's remaining builders) replaced the builder's own
  # hand-written method_missing — a genuine typo (`banana`, admitted
  # nowhere in the whole grammar) now falls through to Ruby's own plain
  # NoMethodError instead, so the OLD probe (any unknown word producing
  # a full "must be X, Y, or Z" list) no longer applies. A word admitted
  # SOMEWHERE ELSE in the grammar but not in this context still gets
  # WordGate's own richer, table-driven refusal, which names this
  # context's full legal-word list — `identified_by` (real, Aggregate
  # context) stands in for the old `banana` probe.
  it "names the same kinds WordGate refuses toward" do
    builder = Hecks::Bluebook::DSL::TranslationAggregateBuilder.new("Account")
    message = begin
      builder.identified_by :whatever
      nil
    rescue Hecks::Bluebook::DSL::Malformed => e
      e.message
    end

    named = message[/legal words here: (.+)\z/, 1].split(", ")
    expect(named).to match_array(AGGREGATE_RULES)
  end
end
