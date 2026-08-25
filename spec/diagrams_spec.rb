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

  # A `to:`-DECLARING PORT OPERATION, IN-MEMORY — no domain in the real
  # corpus uses `to:` yet (PR #351's own real motivating case,
  # lifeadelics' vendored PaymentGateway, lives outside this repo; the
  # corpus's one real port, pizzas' own PaymentGateway.Receive, doesn't
  # happen to need a receiver reference at all). Built the same way
  # other specs cover a real grammar feature the shipped corpus hasn't
  # reached yet (`spec/one_of_spec.rb`'s own `boot_banking` fixture is
  # the precedent).
  def boot_scratch_with_port_routing
    registry = Hecks::Runtime::Registry.new
    Hecks.with_registry(registry) do
      Hecks.bluebook "Scratch" do
        aggregate "Payment" do
          identified_by :reference
          attribute :reference, PaymentReference
          value_object "PaymentReference" do
            attribute :value, String
          end
          command "Create" do
            attribute :reference, PaymentReference
            sets :reference
            emits "PaymentCreated"
          end
        end
      end
      Hecks.hecksagon "Scratch" do
        Scratch::Payment.port "PaymentGateway" do
          operation "Succeeded", to: Payment do
            attribute :reference, PaymentReference
            emits "PaymentSucceeded"
          end
        end
      end
    end
    registry
  end

  # A REAL FILE BOOT, NOT `boot_in_memory` — that helper's own inline
  # hecksagon fixture (spec_helper.rb) only declares `persisted_by`,
  # never the real `pizzas.hecksagon`'s own `port "PaymentGateway"`
  # block, so it silently has no ports at all. Harmless for every check
  # that never touched a port; a real gap the moment `ports.mmd` exists
  # — this spec's own job is "matches what bin/project_diagrams would
  # really generate", and that script boots the real file tree, not a
  # reduced double.
  let(:pizzas_chapter) { Hecks.boot(File.expand_path("../examples/pizzas", __dir__)).registry.bluebook("Pizzas") }
  let(:banking_chapter) { boot_banking.bluebook("Banking") }
  let(:scratch_chapter) { boot_scratch_with_port_routing.bluebook("Scratch") }
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

  # ── roles -> flowchart ───────────────────────────────────────────────

  it "draws exactly one edge per real command whose role is declared, in banking" do
    diagram = Hecks::Projector.call(:diagrams, bluebook: banking_chapter)["roles.mmd"]
    with_role = banking_chapter.aggregates.flat_map { |a| [a, *a.entities] }
                               .flat_map(&:commands).count(&:role)

    drawn = diagram.lines.count { |line| line.include?("|issues|") }
    expect(drawn).to eq(with_role)
  end

  it "draws nothing for a command with no declared role" do
    diagram = Hecks::Projector.call(:diagrams, bluebook: banking_chapter)["roles.mmd"]
    expect(diagram).not_to include("CardPayment.Authorize") # a real command in the corpus with role: nil
  end

  it "sanitizes a multi-word role into a legal id while keeping the real name as the label" do
    diagram = Hecks::Projector.call(:diagrams, bluebook: banking_chapter)["roles.mmd"]
    expect(diagram).to include("role_Back_office((Back office))")
  end

  it "generates a real, non-empty roles.mmd for pizzas too, not just banking" do
    diagram = Hecks::Projector.call(:diagrams, bluebook: pizzas_chapter)["roles.mmd"]
    expect(diagram).to include("role_Chef((Chef))")
  end

  # ── ports -> flowchart ───────────────────────────────────────────────

  it "draws exposes and emits for pizzas' real PaymentGateway.Receive, with no to: edge (none is declared)" do
    diagram = Hecks::Projector.call(:diagrams, bluebook: pizzas_chapter)["ports.mmd"]
    expect(diagram).to include('Order[(Order)] -.->|exposes| op_Order_PaymentGateway_Receive[/"PaymentGateway.Receive"/]')
    expect(diagram).to include("op_Order_PaymentGateway_Receive[/\"PaymentGateway.Receive\"/] -->|emits| evt_PizzaPaymentReceived{{\"PizzaPaymentReceived\"}}")
    expect(diagram).not_to include("|to:")
  end

  it "draws no ports.mmd for banking at all — the real corpus declares no port there" do
    expect(Hecks::Projector.call(:diagrams, bluebook: banking_chapter)["ports.mmd"]).to be_nil
  end

  it "draws a to: edge to the exact aggregate a port operation names, once PR #351's grammar is actually used" do
    diagram = Hecks::Projector.call(:diagrams, bluebook: scratch_chapter)["ports.mmd"]
    expect(diagram).to include('op_Payment_PaymentGateway_Succeeded[/"PaymentGateway.Succeeded"/] -->|to: Payment| Payment[(Payment)]')
  end

  # A STRUCTURAL CHECK, NOT A MERMAID PARSE — this repo's own suite takes
  # no Node/npm dependency for that. Every diagram this projection can
  # currently produce (all 20, across both real domains plus the one
  # in-memory to: fixture) WAS run through the real mermaid.parse()
  # engine once, by hand, to confirm this exact shape is valid Mermaid
  # — this just guards the one structural fact that made that true for
  # each kind: the diagram type declaration is the first non-comment
  # line.
  it "is shaped like real Mermaid in every generated file — the diagram type declared first" do
    expectations = {
      [:pizzas_chapter, "Order_lifecycle.mmd"] => "stateDiagram-v2",
      [:pizzas_chapter, "dispatch.mmd"]        => "flowchart LR",
      [:pizzas_chapter, "roles.mmd"]           => "flowchart LR",
      [:pizzas_chapter, "ports.mmd"]           => "flowchart LR",
      [:banking_chapter, "relationships.mmd"]  => "erDiagram",
      [:banking_chapter, "dispatch.mmd"]       => "flowchart LR",
      [:banking_chapter, "roles.mmd"]          => "flowchart LR",
      [:scratch_chapter, "ports.mmd"]          => "flowchart LR"
    }

    expectations.each do |(chapter_method, filename), expected_first_line|
      files = Hecks::Projector.call(:diagrams, bluebook: send(chapter_method))
      lines = files.fetch(filename).lines.map(&:strip).reject(&:empty?)
      first_real_line = lines.find { |line| !line.start_with?("%%") }
      expect(first_real_line).to eq(expected_first_line), "#{filename}: expected #{expected_first_line.inspect} first"
    end
  end
end
