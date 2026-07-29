
require "spec_helper"

# The language does not only judge a bluebook — it HOLDS one, and gives it back.
#
# `bluebook.bluebook`'s own vision says "loading a domain becomes dispatching
# commands into this meta-domain ; the IR it stores must equal the IR the DSL
# builder produces." Only the first half was true. The judge dispatched every
# declaration in, collected refusals, and threw the records away — which is all
# JUDGING needs, and exactly why the language could only validate.
#
# The reason was structural and slightly absurd: the meta-domain declared twelve
# categories and thirty-four verbs and NOT ONE QUERY. It was write-only. A store
# you cannot read cannot be the source of anything.
#
# So the way back is declared, on the aggregates themselves, and read through
# their own front doors rather than by reaching into a repository. This spec is
# the first slice of it: the chapter and its aggregates come back out. The
# remaining categories, and equality with the builder's whole `to_h`, are the arc
# this opens — not a claim it already makes.
RSpec.describe "the language holds a bluebook, and gives it back" do
  def pizzas
    @pizzas ||= begin
      registry = Hecksagain::Runtime::Registry.new
      Hecksagain.with_registry(registry) do
        Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
        Kernel.load(InMemoryDomain::EXTRACTION_PORT)
        Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
        Kernel.load(InMemoryDomain::PRISM_ADAPTER)
        Kernel.load(File.join(InMemoryDomain::ROOT, "examples/pizzas/bluebook/pizzas.bluebook"))
      end
      registry.bluebook("Pizzas")
    end
  end

  # Dispatch a real bluebook into the meta-domain and KEEP the runtime, which is
  # the only difference between judging and holding.
  def held
    @held ||= begin
      runtime = Hecksagain::Bluebook::MetaValidator.fresh_runtime
      judge   = Hecksagain::Bluebook::MetaValidator::Judge.allocate
      judge.instance_variable_set(:@bluebook, pizzas)
      judge.instance_variable_set(:@refusals, [])
      judge.instance_variable_set(:@runtime, runtime)
      judge.instance_variable_set(
        :@plan,
        Hecksagain::Bluebook::MetaValidator::Plan.for(Hecksagain::Bluebook::MetaValidator.grammar_registry)
      )
      judge.send(:judge!)
      [runtime, judge.instance_variable_get(:@refusals)]
    end
  end

  def runtime  = held.first
  def refusals = held.last

  # Every attribute of the meta-domain is a single-field value object, so a row's
  # cell arrives as a Value rather than a String.
  def text(cell)
    return cell.to_h.values.first if cell.respond_to?(:to_h) && !cell.is_a?(String)

    cell
  end

  it "accepts the bluebook without refusing any of it" do
    expect(refusals).to be_empty
  end

  it "gives the chapter back, by name" do
    rows = runtime.query("Meta::Bluebook.Named", name: { value: "Pizzas" })

    expect(rows.size).to eq(1)
    expect(text(rows.first[:name])).to eq(pizzas.name)
    expect(text(rows.first[:vision])).to eq(pizzas.vision)
    expect(text(rows.first[:classification])).to eq(pizzas.classification)
  end

  it "gives back every aggregate the chapter declared" do
    rows = runtime.query("Meta::Aggregate.Of", bluebook_id: { value: "Pizzas" })

    expect(rows.map { |row| text(row[:name]) }).to eq(pizzas.aggregates.map(&:name))
  end

  it "reads through the aggregate's own query, not a repository" do
    # Persistence is an adapter BELOW the aggregate. If the way back reached into
    # a repository it would bypass the rules, the authorisation and the shape that
    # every writer goes through — and the read side would drift from the write
    # side exactly as the two runtimes' tables used to.
    expect(Hecksagain::Bluebook::MetaValidator.grammar_registry
             .bluebook("Meta").aggregates
             .flat_map { |a| a.queries.map { |q| "#{a.name}.#{q.name}" } })
      .to include("Bluebook.Named", "Aggregate.Of")
  end
end
