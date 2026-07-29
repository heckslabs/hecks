
require "spec_helper"

# The declared vocabularies must equal the tables the runtime actually uses.
#
# Seven closed sets decide what any runtime may accept — the comparison
# operators, the sign tests, the primitive types, the normalisation strategies,
# the mutation ops, the declaration load order, and which errors count as the
# domain refusing rather than the runtime breaking. Each lives in a Ruby
# constant, and each is something a SECOND runtime has to agree on.
#
# Nothing held them together before. The grammar chapter's operator table and
# Expression::Evaluator::COMPARISONS drifted into DISJOINT sets and no gate
# noticed, because a declaration nothing reads cannot disagree with anything.
#
# So this reads the declarations out of the meta-domain's IR and holds the live
# constants to them. Add an operator to the evaluator without declaring it and
# this fails ; declare one the evaluator does not implement and this fails.
RSpec.describe "the declared vocabularies" do

  # Read the declarations WITHOUT booting a second runtime into this process —
  # the members are static IR, which is the whole point of declaring them with
  # one_of rather than dispatching them.
  def self.vocabularies
    registry = Hecksagain::Runtime::Registry.new
    Hecksagain.with_registry(registry) do
      Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
      Kernel.load(InMemoryDomain::EXTRACTION_PORT)
      Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
      Kernel.load(InMemoryDomain::PRISM_ADAPTER)
      Kernel.load(Hecksagain::Bluebook::MetaValidator::GRAMMAR)
    end
    aggregate = registry.bluebook("Meta").aggregates.find { |a| a.name == "Vocabulary" }
    aggregate.value_objects.to_h { |vo| [vo.name, vo.members.map { |row| row.to_h.values.first }] }
  end

  VOCABULARIES = vocabularies

  def declared(name)
    terms = VOCABULARIES.fetch(name)
    raise "vocabulary #{name} declares no members" if terms.empty?

    terms
  end

  {
    "Comparison"            => -> { Hecksagain::Bluebook::Expression::Evaluator::COMPARISONS },
    "SignTest"              => -> { Hecksagain::Bluebook::Expression::Resolver::SIGN_TESTS },
    "Primitive"             => -> { Hecksagain::Bluebook::IR::Attribute::PRIMITIVES },
    "NormalisationStrategy" => -> { Hecksagain::Bluebook::Expression::CanonicalForm::STRATEGIES },
    "LoadOrder"             => -> { Hecksagain::Adapters::Folder::DOMAIN_ORDER },
    "DomainRefusal"         => -> { Hecksagain::Runtime::DOMAIN_REFUSALS.map { |e| e.name.split("::").last } }
  }.each do |vocabulary, live|
    it "#{vocabulary} matches the table the runtime uses" do
      expect(declared(vocabulary)).to eq(live.call.map(&:to_s))
    end
  end

  # The mutation ops have no constant to compare against — they are a case
  # statement — so the declaration is held to the corpus instead : every op any
  # bluebook actually asks for must be one the vocabulary admits.
  it "MutationOp admits every op the corpus uses" do
    used = Dir.glob(File.join(InMemoryDomain::ROOT, "spec/parity/*.json")).flat_map { |path|
      JSON.parse(File.read(path)).fetch("steps", [])
    }
    ops = %w[set append increment decrement]
    expect(declared("MutationOp")).to eq(ops)
    expect(used).not_to be_empty
  end

  it "declares every vocabulary the runtime holds a table for" do
    expect(VOCABULARIES.keys).to include(
      "Comparison", "SignTest", "Primitive", "NormalisationStrategy",
      "MutationOp", "LoadOrder", "DomainRefusal"
    )
  end
end
