
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
    registry = Hecksagain::Runtime::Registry.new
    Hecksagain.with_registry(registry) do
      Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
      Kernel.load(InMemoryDomain::EXTRACTION_PORT)
      Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
      Kernel.load(InMemoryDomain::PRISM_ADAPTER)
      Kernel.load(File.join(InMemoryDomain::ROOT, "lib/hecksagain/grammar/translation.bluebook"))
    end
    kind = registry.bluebook("Translation").aggregate("Rule").value_object("Kind")
    [kind, kind.members.map { |row| row.to_h.values.first }]
  end

  KIND_OBJECT, DECLARED_KINDS = declared_kinds

  # The builder's own rule methods, introspected rather than listed — add a
  # rule to the DSL without declaring it and this fails; declare one the DSL
  # does not implement and this fails.
  AGGREGATE_RULES = (
    Hecksagain::Bluebook::DSL::TranslationAggregateBuilder.public_instance_methods(false) -
      [:build, :method_missing]
  ).map(&:to_s).sort.freeze

  it "declares Kind as a closed set, not an open string" do
    expect(KIND_OBJECT.closed_set?).to be(true)
    expect(DECLARED_KINDS).not_to be_empty
  end

  it "matches the rule methods TranslationAggregateBuilder admits" do
    expect(DECLARED_KINDS - %w[retired]).to match_array(AGGREGATE_RULES)
  end

  it "declares retired, the edge-level kind, which the edge builder admits" do
    expect(DECLARED_KINDS).to include("retired")
    expect(Hecksagain::Bluebook::DSL::TranslationBuilder.public_instance_methods(false)).to include(:retired)
  end

  it "names the same kinds method_missing refuses toward" do
    builder = Hecksagain::Bluebook::DSL::TranslationAggregateBuilder.new("Thing")
    message = begin
      builder.banana
      nil
    rescue Hecksagain::Bluebook::DSL::Malformed => e
      e.message
    end

    named = message[/must be (.+?) — got/, 1].split(",").map { |word| word.strip.sub(/\Aor\s+/, "") }
    expect(named).to match_array(AGGREGATE_RULES)
  end
end
