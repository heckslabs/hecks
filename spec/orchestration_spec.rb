require "spec_helper"

# THE LANGUAGE IS THE SOURCE, and this is what holds it to that.
#
# `MetaValidator.call` returns `Assembly.call(held[:declaration])` — the graph the
# meta-domain HOLDS — and `Hecks.bluebook` registers whatever comes back, so the
# runtime runs the language's graph and not the builder's. The builder's own graph
# exists only to be dispatched in ; nothing keeps it.
#
# This spec compares the two graphs FIELD BY FIELD, TYPE INCLUDED, and there is
# nothing left in the gap list. Type included is the whole point: `to_h`
# stringifies, so byte equality cannot see a Symbol that came back a String, and
# five real breaks hid exactly there —
#
#   an entity's `identified_by`     "pass sequence:", while sequence was passed
#   a procedure's `correlates_by`   the settlement wire never advanced
#   a saga leg's object literal     the debit leg was never delivered
#   a closed set's member values    a set admitting "0" refusing the 0 passed
#   an aggregate's reference targets Pizza pointing at itself, twice
#
# Each looked identical on the wire and stopped the runtime dead. Only running
# the corpus end to end (spec/corpus/ scripts do this now)
# caught the third, because a saga that silently does nothing looks exactly like a
# saga with nothing to do.
RSpec.describe "the distance between the builder's graph and the language's" do
  ORCHESTRATION_CORPUS = {
    "Pizzas"     => "examples/pizzas/bluebook/pizzas.bluebook",
    "Banking"    => "examples/banking/bluebook/banking.bluebook",
    "Expression" => "lib/hecksagain/grammar/expression.bluebook",
    "TillRoom"   => "spec/fixtures/till.bluebook",
    "Wire"       => "spec/fixtures/settlement.bluebook",
    "Reflex"     => "spec/fixtures/reflex.bluebook"
  }.freeze

  # EMPTY, AND IT HAS TO STAY THAT WAY.
  #
  # It held thirteen entries, all of them justified by the same wrong belief: that
  # the language may only hold what `to_h` carries. `ReadModel#to_h` omits a read
  # model's filters, and a hoisted
  # policy lost which head declared it — so all of that looked unrecoverable.
  #
  # It was not. `to_h` is a PROJECTION for consumers ; the language is the
  # SOURCE. They must agree about everything to_h spells and need not be the same
  # size. Both are held now — the filters as option rows, the policy's head as a
  # field — and the wire format did not move, so no consumer noticed.
  #
  # Anything added here from now on is a claim that the language cannot hold
  # something, and that claim should be very hard to make.
  KNOWN_GAPS = [].freeze

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

  # Walks OBJECT STATE. Deliberately not `to_h`: that is the wire spelling, and it
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
    when Class
      ivars(node).each { |iv| state(node.instance_variable_get(iv), "#{path}.#{iv}", out, depth + 1) }
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
    held = Hecksagain::Bluebook::MetaValidator.hold(built)
    expect(held[:refusals]).to be_empty, "the language refused it: #{held[:refusals].inspect}"

    Hecksagain::Bluebook::Assembly.call(held[:declaration])
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

  it "keeps the gap list empty, because there is nothing it cannot hold" do
    expect(KNOWN_GAPS).to be_empty
  end

  it "registers the language's graph, not the one the builder made" do
    # The swap, asserted rather than described: what comes back from the door
    # `Hecks.bluebook` registers through is a DIFFERENT object from the one handed
    # in, assembled from records. Sabotaging the assembly fails 136 examples, which
    # is the other half of the same proof — the runtime depends on this, it does not
    # merely tolerate it.
    built = load_chapter(ORCHESTRATION_CORPUS.fetch("Pizzas")).bluebook("Pizzas")

    expect(Hecksagain::Bluebook::MetaValidator.call(built)).not_to be(built)
  end
end
