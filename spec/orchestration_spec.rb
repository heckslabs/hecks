
require "spec_helper"

# HOW FAR THE LANGUAGE IS FROM BEING THE SOURCE, measured rather than asserted.
#
# `MetaValidator.call` returns the bluebook it was handed. Returning
# `Assembly.call(held[:declaration])` instead is the whole swap, because
# `Hecks.bluebook` registers whatever comes back from there — the runtime would run
# what the meta-domain HOLDS rather than what the builder made.
#
# That was tried. The corpus runs, both runtimes agree, and the wire format does
# not move. What stops it is a short list of things the IR itself does not carry,
# and this spec compares the two graphs FIELD BY FIELD, TYPE INCLUDED, and holds
# the differences to exactly that list.
#
# Type included is the point. `to_h` stringifies, so byte equality cannot see a
# Symbol that came back a String — and three real breaks hid there: an entity's
# `identified_by`, a procedure's `correlates_by`, and a saga leg binding an object
# literal. Each one looked identical on the wire and stopped the runtime dead.
RSpec.describe "the distance between the builder's graph and the language's" do
  ORCHESTRATION_CORPUS = {
    "Pizzas"     => "examples/pizzas/bluebook/pizzas.bluebook",
    "Banking"    => "examples/banking/bluebook/banking.bluebook",
    "Expression" => "lib/hecksagain/grammar/expression.bluebook",
    "TillRoom"   => "spec/fixtures/till.bluebook",
    "Wire"       => "spec/fixtures/settlement.bluebook",
    "Reflex"     => "spec/fixtures/reflex.bluebook"
  }.freeze

  # What the IR cannot carry, so the language cannot hold it, so an assembled graph
  # cannot have it. Each entry is a claim about the WIRE FORMAT, not about the
  # assembly — closing any of them changes `to_h` and therefore Rust.
  #
  #   @policies         `Aggregate#to_h` omits them. A policy declared inside a head
  #                     is hoisted onto the chapter, which is where the runtime
  #                     reads it, so nothing is lost at runtime — only the record of
  #                     which head declared it.
  #   @wheres @order_by @limit @offset @cursor @consistency @freshness
  #   @authorization @null_semantics @inspection @index_hints @joins
  #                     on a READ MODEL only. `ReadModel#to_h` omits every one, and
  #                     so does Rust's ReadModel struct — five fields, no filters.
  #                     A read model's filtering has never been in the contract.
  KNOWN_GAPS = %w[
    @policies @wheres @order_by @limit @offset @cursor @consistency @freshness
    @authorization @null_semantics @inspection @index_hints @joins
  ].freeze

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
  SKIP = %i[@ruby_class @hecks_owner @declared_in @predicate].freeze

  def state(node, path, out, depth = 0)
    return if depth > 14

    case node
    when Symbol, String, Numeric, TrueClass, FalseClass, NilClass
      out[path] = "#{node.inspect} (#{node.class})"
    when Array then node.each_with_index { |held, i| state(held, "#{path}[#{i}]", out, depth + 1) }
    when Hash  then node.each { |key, held| state(held, "#{path}.#{key}(#{key.class})", out, depth + 1) }
    when Proc  then out[path] = "(proc)"
    when Class
      return out[path] = "aggregate-class" if node < Hecksagain::Aggregate

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

  it "assembles a working runtime surface from what the language holds" do
    built     = load_chapter(ORCHESTRATION_CORPUS.fetch("Pizzas")).bluebook("Pizzas")
    assembled = assembled_from_the_language(built)
    pizza     = assembled.aggregate("Pizza").ruby_class

    expect(pizza).to respond_to(:create_pizza)
    expect(pizza.instance_methods).to include(:add_topping, :purchase, :toppings, :status)
    expect(pizza::Price.hecks_fqn).to eq("Pizzas::Pizza.Price")
    expect(assembled.aggregate("Pizza").command("AddTopping").acts_on).to be(pizza)
  end

  it "keeps the gap list honest by naming what is still in it" do
    # If a gap closes, the list must shrink — otherwise it stops describing anything
    # and starts excusing everything. Read models are the whole of it apart from
    # aggregate-level policies.
    expect(KNOWN_GAPS).to include("@policies")
    expect(KNOWN_GAPS).to include("@wheres")
    expect(KNOWN_GAPS.size).to eq(13)
  end
end
