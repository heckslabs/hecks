
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

  it "gives back the bluebook called Pizzas" do
    rows = runtime.query("Meta::Bluebook.Called", name: { value: "Pizzas" })

    expect(rows.size).to eq(1)
    expect(text(rows.first[:name])).to eq(pizzas.name)
    expect(text(rows.first[:vision])).to eq(pizzas.vision)
    expect(text(rows.first[:classification])).to eq(pizzas.classification)
  end

  it "gives back every aggregate declared in it" do
    rows = runtime.query("Meta::Aggregate.DeclaredIn", bluebook_id: { value: "Pizzas" })

    expect(rows.map { |row| text(row[:name]) }).to eq(pizzas.aggregates.map(&:name))
  end

  it "hands back the whole bluebook in one read" do
    # The twelve DeclaredIn queries can walk the tree a level at a time, and a
    # caller stitching twelve reads together is a caller reimplementing this. The
    # language already knows how to say "gather these heads around that spine".
    rows = runtime.query("Meta.whole_bluebook", bluebook: "Pizzas")
    whole = rows.first

    expect(whole.keys).to eq(
      %i[bluebook aggregates commands value_objects queries entities members
         policies process_managers handlers dispatches read_models]
    )
    expect(whole[:aggregates].map { |a| text(a[:name]) }).to eq(pizzas.aggregates.map(&:name))
    expect(whole[:commands].map { |c| text(c[:name]) })
      .to match_array(pizzas.aggregates.flat_map { |a| a.commands.map(&:name) })
  end

  it "keeps declaration order when read a level at a time" do
    # The IR is a contract field for field AND INDEX FOR INDEX, so the order a
    # bluebook declares its commands in is a fact about the source. `DeclaredIn`
    # preserves it.
    rows = runtime.query("Meta::Command.DeclaredIn", aggregate_id: { value: "Pizzas::Pizza" })

    expect(rows.map { |row| text(row[:name]) })
      .to eq(pizzas.aggregate("Pizza").commands.map(&:name))
  end

  it "does NOT keep declaration order in the whole-bluebook read model" do
    # And this is why the reconstruction has to read a level at a time rather than
    # take the convenient snapshot. ReadModelInterpreter#matching ends `.sort_by(&:id)`
    # — deliberately, because two hand-written stores cannot be trusted to iterate
    # identically and a read model that returned store order would split parity.
    #
    # So the two ways back are for different jobs: the read model hands you the
    # whole chapter when order does not matter, and DeclaredIn is what you rebuild
    # an IR from. Pinned because it is a live trap: the read model is the nicer
    # call, and using it would produce a reconstruction that differs from the
    # source in a way nothing else would notice.
    whole = runtime.query("Meta.whole_bluebook", bluebook: "Pizzas").first
    declared = pizzas.aggregate("Pizza").commands.map(&:name)

    expect(whole[:commands].map { |c| text(c[:name]) }).to eq(declared.sort)
    expect(declared).not_to eq(declared.sort)
  end

  it "names a gathered collection the way English does" do
    # These four came back as `querys`, `entitys`, `policys` and `dispatchs`, in
    # BOTH runtimes, because each derived the name with snake(target) + "s". Parity
    # was green on every one of them — two hand-written runtimes identically
    # wrong. The pluraliser now lives in one place per runtime, mirroring the same
    # three rules.
    expect(Hecksagain::Naming.plural("query")).to eq("queries")
    expect(Hecksagain::Naming.plural("entity")).to eq("entities")
    expect(Hecksagain::Naming.plural("policy")).to eq("policies")
    expect(Hecksagain::Naming.plural("dispatch")).to eq("dispatches")
    expect(Hecksagain::Naming.plural("value_object")).to eq("value_objects")
    # a vowel before the y is not a plural rule — day, not daies
    expect(Hecksagain::Naming.plural("day")).to eq("days")
  end

  it "reads through the aggregate's own query, not a repository" do
    # Persistence is an adapter BELOW the aggregate. If the way back reached into
    # a repository it would bypass the rules, the authorisation and the shape that
    # every writer goes through — and the read side would drift from the write
    # side exactly as the two runtimes' tables used to.
    expect(Hecksagain::Bluebook::MetaValidator.grammar_registry
             .bluebook("Meta").aggregates
             .flat_map { |a| a.queries.map { |q| "#{a.name}.#{q.name}" } })
      .to include("Bluebook.Called", "Aggregate.DeclaredIn")
  end
end
