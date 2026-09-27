require "spec_helper"

# Compares the builder's graph with the one the language (MetaValidator/Assembly) holds,
# field by field and type included: `to_h` stringifies, so a Symbol that came back a
# String is invisible on the wire yet stops the runtime.
RSpec.describe "the distance between the builder's graph and the language's" do
  ORCHESTRATION_CORPUS = {
    "Pizzas"     => "examples/pizzas/bluebook/pizzas.bluebook",
    "Banking"    => InMemoryDomain::BANKING_BLUEBOOK_DIR,
    "Expression" => "lib/hecks/grammar/expression.bluebook",
    "TillRoom"   => "spec/fixtures/till.bluebook",
    "Wire"       => "spec/fixtures/settlement.bluebook",
    "Reflex"     => "spec/fixtures/reflex.bluebook"
  }.freeze

  # Must stay empty: the language must hold everything `to_h` spells, though `to_h` may
  # carry less. Adding an entry claims the language cannot hold something.
  KNOWN_GAPS = [].freeze

  def load_chapter(file)
    registry = Hecks::Runtime::Registry.new
    Hecks.with_registry(registry) do
      Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
      Kernel.load(InMemoryDomain::EXTRACTION_PORT)
      Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
      Kernel.load(InMemoryDomain::PRISM_ADAPTER)
      path = File.absolute_path(file, InMemoryDomain::ROOT)
      load_bluebook_files(path)
    end
    registry
  end

  # Walks object state. Deliberately not `to_h`: that is the wire spelling, and it
  # is where the types go.
  SKIP = %i[@hecks_owner @declared_in @predicate].freeze

  def state(node, path, out, depth = 0)
    return if depth > 14

    case node
    when Symbol, String, Numeric, TrueClass, FalseClass, NilClass
      out[path] = "#{node.inspect} (#{node.class})"
    when Array then node.each_with_index { |held, i| state(held, "#{path}[#{i}]", out, depth + 1) }
    when Hash  then node.each { |key, held| state(held, "#{path}.#{key}(#{key.class})", out, depth + 1) }
    when Proc  then out[path] = "(proc)"
    else
      ivars(node).each { |iv| state(node.instance_variable_get(iv), "#{path}.#{iv}", out, depth + 1) }
    end
  end

  def ivars(node) = node.instance_variables - SKIP

  def snapshot(chapter)
    out = {}
    state(chapter, "", out)
    out
  end

  def assembled_from_the_language(built)
    held = Hecks::Bluebook::MetaValidator.hold(built)
    expect(held[:refusals]).to be_empty, "the language refused it: #{held[:refusals].inspect}"

    Hecks::Bluebook::Assembly.call(held[:declaration])
  end

  ORCHESTRATION_CORPUS.each do |name, file|
    it "differs on #{name} only where the IR cannot carry it" do
      built     = load_chapter(file).bluebook(name)
      before    = snapshot(built)
      assembled = snapshot(assembled_from_the_language(built))

      surprising = (before.keys | assembled.keys).reject do |path|
        before[path] == assembled[path] || KNOWN_GAPS.any? { |gap| path.include?(gap) }
      end

      expect(surprising).to be_empty,
                            "#{name} came back different in #{surprising.size} place(s) the wire format " \
                            "does carry, so the language is losing something it holds:\n  " +
                            surprising.first(12).map { |path|
                              "#{path}\n      built     #{before[path].inspect}\n      assembled #{assembled[path].inspect}"
                            }.join("\n  ")
    end
  end

  it "assembles a working runtime graph from what the language holds" do
    built     = load_chapter(ORCHESTRATION_CORPUS.fetch("Pizzas")).bluebook("Pizzas")
    assembled = assembled_from_the_language(built)
    pizza     = assembled.aggregate("Order")

    expect(pizza.command("CreatePizza").creates?).to be(true)
    expect(pizza.command("AddTopping").acts_on).to be(pizza)
    expect(pizza.attribute(:toppings)).not_to be_nil
    expect(pizza.value_object("Price").hecks_fqn).to eq("Pizzas::Order.Price")
  end

  it "registers the language's graph, not the one the builder made" do
    # The door `Hecks.bluebook` registers through returns an object assembled from
    # records, not the one handed in.
    built = load_chapter(ORCHESTRATION_CORPUS.fetch("Pizzas")).bluebook("Pizzas")

    expect(Hecks::Bluebook::MetaValidator.call(built)).not_to be(built)
  end
end
