
require "spec_helper"

# A GRAPH ASSEMBLED FROM DECLARATIONS IS THE GRAPH THE BUILDER MAKES.
#
# `Assembly` takes the hash `to_h` spells and returns the object graph the runtime
# runs. That makes it the exact inverse of `to_h`, and this holds it to that for
# every chapter in the tree:
#
#     Assembly.call(built.to_h).to_h == built.to_h
#
# It is tested against the BUILDER's hash rather than the meta-domain's on purpose.
# The two are already proven byte-identical and unsorted by spec/round_trip_spec, so
# feeding the builder's keeps this spec about one thing — whether declarations
# rebuild into objects faithfully — instead of two.
#
# Every chapter, not the four the round trip walks: a shape only one bluebook
# exercises is exactly the shape a partial corpus lets through.
RSpec.describe "a graph assembled from declarations" do
  # Reachable both from the example group, to generate the examples, and from
  # inside one.
  ASSEMBLY_CORPUS = {
    "Pizzas"     => "examples/pizzas/bluebook/pizzas.bluebook",
    "Banking"    => "examples/banking/bluebook/banking.bluebook",
    "Expression" => "lib/hecksagain/grammar/expression.bluebook",
    "TillRoom"   => "spec/fixtures/till.bluebook",
    "Wire"       => "spec/fixtures/settlement.bluebook",
    "Reflex"     => "spec/fixtures/reflex.bluebook"
  }.freeze

  def load_chapter(file)
    registry = Hecksagain::Runtime::Registry.new
    Hecksagain.with_registry(registry) do
      Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
      Kernel.load(InMemoryDomain::EXTRACTION_PORT)
      Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
      Kernel.load(InMemoryDomain::PRISM_ADAPTER)
      Kernel.load(File.join(InMemoryDomain::ROOT, file))
    end
    registry
  end

  # Names the field that moved rather than dumping two documents.
  def differences(source, back, path = "")
    return [] if source == back

    if source.is_a?(Hash) && back.is_a?(Hash)
      (source.keys | back.keys).flat_map { |key| differences(source[key], back[key], "#{path}.#{key}") }
    elsif source.is_a?(Array) && back.is_a?(Array) && source.size == back.size
      source.each_with_index.flat_map { |held, i| differences(held, back[i], "#{path}[#{i}]") }
    else
      ["#{path}: declared #{source.inspect[0, 70]}, assembled #{back.inspect[0, 70]}"]
    end
  end

  def assert_inverse(built)
    assembled = Hecksagain::Bluebook::Assembly.call(built.to_h)

    expect(differences(built.to_h, assembled.to_h)).to be_empty
  end

  ASSEMBLY_CORPUS.each do |name, file|
    it "rebuilds #{name} exactly as it was declared" do
      assert_inverse(load_chapter(file).bluebook(name))
    end
  end

  %w[Meta Deployment].each do |name|
    it "rebuilds #{name}, the language itself, exactly as it was declared" do
      assert_inverse(Hecksagain::Bluebook::MetaValidator.grammar_registry.bluebook(name))
    end
  end

  describe "the table, held to the language" do
    def plan
      Hecksagain::Bluebook::MetaValidator::Plan.for(
        Hecksagain::Bluebook::MetaValidator.grammar_registry
      )
    end

    # EVERY FIELD THE LANGUAGE DECLARES IS EITHER ASSEMBLED OR NAMED AS DERIVED.
    #
    # This is the judge-coverage lesson, in the other direction. The judge used to
    # carry a hand-written branch per category, and the price was fourteen verbs the
    # language declared and the walk never offered — every rule hanging off them
    # decoration, and nothing red, because a branch that does not exist cannot fail.
    # An assembler with a method per category is the same shape, so the table is
    # checked against the language rather than hand-kept: add a field to
    # bluebook.bluebook and forget to assemble it, and this says so.
    # Read off the aggregate's OWN ATTRIBUTES, not only the creating command's
    # arguments. `Plan#fields` is the latter, and the first draft of this example
    # used it — so adding `attribute :nickname` to the language's Bluebook passed
    # unnoticed, because nothing had taught `Declare` to carry it yet. What an
    # assembly must account for is what the language STORES.
    def stored_fields(meta, category)
      aggregate = meta.aggregate(category)
      declared  = plan.category(category)

      (aggregate.attributes.map(&:name) +
       declared.fields.map(&:to_sym) +
       declared.appends.keys.map(&:to_sym) +
       declared.setters.flat_map { |setter| setter.targets.keys.map(&:to_sym) })
        .uniq
        # A PARENT POINTER is derived by structure, not by a contract. Every `*_id`
        # here is the reference to whatever declares the construct — an aggregate's
        # chapter, a verb's head, a piece's head, a member's shape — and the
        # containment tree already knows it, which is precisely how the assembly
        # walks. Requiring thirteen contracts to each restate one would be a list
        # nobody reads, and the day one went stale it would say nothing.
        .reject { |field| field.to_s.end_with?("_id") }
    end

    it "consumes or explicitly derives every field the language declares" do
      meta = Hecksagain::Bluebook::MetaValidator.grammar_registry.bluebook("Meta")

      unclaimed = plan.names.flat_map do |category|
        contract = Hecksagain::Bluebook::Assembly.contract(category)

        stored_fields(meta, category)
          .reject { |field| contract.declares?(field) }
          .map { |field| "#{category}##{field}" }
      end

      expect(unclaimed).to be_empty,
                           "the language declares #{unclaimed.size} field(s) no contract accounts for, " \
                           "so a graph assembled from them would drop each one in silence:\n  " \
                           "#{unclaimed.join("\n  ")}"
    end

    it "names a contract for every category the language declares" do
      missing = plan.names.reject do |category|
        Hecksagain::Bluebook::Assembly::CONTRACTS.key?(category)
      end

      expect(missing).to be_empty,
                         "the language declares #{missing.join(', ')} and the table has no contract for it"
    end

    it "claims nothing the language does not declare" do
      # The other half of the same failure: a contract for a retired category, or a
      # field renamed in the language and left behind here, would be dead weight
      # nothing exercises.
      declared = plan.names
      phantom  = Hecksagain::Bluebook::Assembly::CONTRACTS.keys - declared

      expect(phantom).to be_empty
    end
  end

  it "gives the assembled head a working Ruby surface, not just an IR" do
    # The graph is what the runtime RUNS, so an assembled aggregate has to carry the
    # same class, verbs and readers the DSL would have defined.
    built     = load_chapter(ASSEMBLY_CORPUS.fetch("Pizzas")).bluebook("Pizzas")
    assembled = Hecksagain::Bluebook::Assembly.call(built.to_h)
    pizza     = assembled.aggregate("Pizza").ruby_class

    expect(pizza.ir).to be(assembled.aggregate("Pizza"))
    expect(pizza).to respond_to(:create_pizza)          # a creating verb, class-side
    expect(pizza.instance_methods).to include(:add_topping, :purchase)
    expect(pizza.instance_methods).to include(:name, :toppings, :status)
    expect(pizza::Price.hecks_fqn).to eq("Pizzas::Pizza.Price")
  end

  it "gives an assembled reference a resolvable edge" do
    built     = load_chapter(ASSEMBLY_CORPUS.fetch("Banking")).bluebook("Banking")
    assembled = Hecksagain::Bluebook::Assembly.call(built.to_h)
    account   = assembled.aggregate("Account")

    expect(account.attribute(:customer_id).type.resolve)
      .to be(assembled.aggregate("Customer").ruby_class)
  end
end
