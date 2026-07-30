
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
