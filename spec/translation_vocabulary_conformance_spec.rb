require "spec_helper"

# The translation chapter's Rule.Kind closed set must equal the rule vocabulary the DSL admits,
# the same drift gate vocabulary_conformance_spec.rb applies to every other closed set.
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

  # Rule methods are introspected, not listed. Words run by `GenericDispatch` come from the grammar
  # table, and their `*_impl` methods are excluded so no word is counted twice.
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

  # `identified_by` is admitted elsewhere in the grammar, so WordGate refuses it with a message
  # naming this context's legal words; a word admitted nowhere would be a plain NoMethodError.
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
