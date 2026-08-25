require "spec_helper"

# docs/generated/diagrams/ is GENERATED from each domain's own declared
# lifecycles, relationships, and dispatch chains by bin/project_diagrams
# (see Projections::Diagrams's own header for why Mermaid, and the shape
# of each of the three diagram kinds) — this spec regenerates each
# domain's set into memory and asserts byte equality with the committed
# files, the same drift-detection shape spec/parser_table_spec.rb
# already holds rust/parser/src/keywords.rs to.
RSpec.describe "the generated diagrams" do
  def boot_banking
    registry = Hecks::Runtime::Registry.new
    Hecks.with_registry(registry) do
      Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
      Kernel.load(InMemoryDomain::EXTRACTION_PORT)
      Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
      Kernel.load(InMemoryDomain::PRISM_ADAPTER)
      load_bluebook_files(InMemoryDomain::BANKING_BLUEBOOK_DIR)
    end
    registry
  end

  let(:pizzas_chapter)  { boot_in_memory.registry.bluebook("Pizzas") }
  let(:banking_chapter) { boot_banking.bluebook("Banking") }
  let(:order)           { pizzas_chapter.aggregates.find { |a| a.hecks_name == "Order" } }

  # ── drift, across both real domains ────────────────────────────────

  def assert_undrifted(domain, chapter)
    committed_dir = File.expand_path("../docs/generated/diagrams/#{domain}", __dir__)
    regenerated = Hecks::Projector.call(:diagrams, bluebook: chapter)
    expect(regenerated).not_to be_empty

    regenerated.each do |relative, contents|
      path = File.join(committed_dir, relative)
      expect(File).to exist(path), "#{domain}/#{relative} is missing — run bin/project_diagrams"
      expect(File.read(path)).to eq(contents),
                                 "#{domain}/#{relative} is stale — run bin/project_diagrams and commit the result"
    end

    expect(Dir.children(committed_dir).sort).to eq(regenerated.keys.sort),
                                                "docs/generated/diagrams/#{domain}/ holds a file the projection no " \
                                                "longer generates, or is missing one it does — run bin/project_diagrams"
  end

  it "is exactly what bin/project_diagrams would regenerate for pizzas right now" do
    assert_undrifted("pizzas", pizzas_chapter)
  end

  it "is exactly what bin/project_diagrams would regenerate for banking right now" do
    assert_undrifted("banking", banking_chapter)
  end

  # ── lifecycle -> stateDiagram-v2 ────────────────────────────────────

  it "draws exactly the edges Order's own lifecycle declares, no more and no fewer" do
    diagram = Hecks::Projector.call(:diagrams, bluebook: pizzas_chapter)["Order_lifecycle.mmd"]
    lifecycle = order.lifecycle

    declared_edges = lifecycle.transitions.flat_map do |command, transition|
      Array(transition.from).map { |from| "#{from} --> #{transition.target}: #{command}" }
    end
    drawn_edges = diagram.lines.map(&:strip).select { |line| line.include?("-->") && !line.start_with?("[*]") }

    expect(drawn_edges.size).to eq(declared_edges.size)
    declared_edges.each { |edge| expect(drawn_edges).to include(edge) }
  end

  it "starts at the lifecycle's own declared default state" do
    diagram = Hecks::Projector.call(:diagrams, bluebook: pizzas_chapter)["Order_lifecycle.mmd"]
    expect(diagram).to include("[*] --> #{order.lifecycle.default}")
  end

  # ── relationships -> erDiagram ──────────────────────────────────────

  it "draws exactly one edge per real relationship attribute in banking, no more and no fewer" do
    diagram = Hecks::Projector.call(:diagrams, bluebook: banking_chapter)["relationships.mmd"]
    holder_attributes = banking_chapter.aggregates.flat_map { |a| [a, *a.entities] }
                                       .flat_map { |h| h.attributes.select(&:reference?) }

    drawn_edges = diagram.lines.map(&:strip).select { |line| line.include?("--") }
    expect(drawn_edges.size).to eq(holder_attributes.size)
  end

  it "reads a required belongs_to/reference_to as an exactly-one marker on the target side" do
    diagram = Hecks::Projector.call(:diagrams, bluebook: banking_chapter)["relationships.mmd"]
    expect(diagram).to include('Customer ||--o{ Account : "customer"')
  end

  it "reads an optional reference_to as a zero-or-one marker on the target side" do
    diagram = Hecks::Projector.call(:diagrams, bluebook: banking_chapter)["relationships.mmd"]
    expect(diagram).to include('Customer |o--o{ CardPayment : "disputed_by"')
  end

  # ── dispatch -> flowchart ────────────────────────────────────────────

  it "draws an emits edge for every real command.emits pair in pizzas" do
    diagram = Hecks::Projector.call(:diagrams, bluebook: pizzas_chapter)["dispatch.mmd"]
    declared = pizzas_chapter.aggregates.flat_map(&:commands).sum { |c| c.emits.size }
    drawn = diagram.lines.count { |line| line.include?("|emits|") }
    expect(drawn).to eq(declared)
  end

  it "wires a policy's own trigger to the real command it names" do
    diagram = Hecks::Projector.call(:diagrams, bluebook: pizzas_chapter)["dispatch.mmd"]
    expect(diagram).to include('evt_PizzaPaymentReceived{{"PizzaPaymentReceived"}} -->|triggers| cmd_Order_Purchase(["Order.Purchase"])')
  end

  it "labels a cross-domain trigger with the domain it crosses into, in banking" do
    diagram = Hecks::Projector.call(:diagrams, bluebook: banking_chapter)["dispatch.mmd"]
    expect(diagram).to include("-->|triggers in Compliance|")
  end

  # A STRUCTURAL CHECK, NOT A MERMAID PARSE — this repo's own suite takes
  # no Node/npm dependency for that. Every diagram this projection can
  # currently produce (all 17, across both real domains) WAS run through
  # the real mermaid.parse() engine once, by hand, to confirm this exact
  # shape is valid Mermaid — this just guards the one structural fact
  # that made that true for each kind: the diagram type declaration is
  # the first non-comment line.
  it "is shaped like real Mermaid in every generated file — the diagram type declared first" do
    expectations = {
      [:pizzas_chapter, "Order_lifecycle.mmd"] => "stateDiagram-v2",
      [:pizzas_chapter, "dispatch.mmd"]        => "flowchart LR",
      [:banking_chapter, "relationships.mmd"]  => "erDiagram",
      [:banking_chapter, "dispatch.mmd"]       => "flowchart LR"
    }

    expectations.each do |(chapter_method, filename), expected_first_line|
      files = Hecks::Projector.call(:diagrams, bluebook: send(chapter_method))
      lines = files.fetch(filename).lines.map(&:strip).reject(&:empty?)
      first_real_line = lines.find { |line| !line.start_with?("%%") }
      expect(first_real_line).to eq(expected_first_line), "#{filename}: expected #{expected_first_line.inspect} first"
    end
  end
end
