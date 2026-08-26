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
  let(:pizzas_registry)  { Hecks.boot(File.expand_path("../examples/pizzas", __dir__)).registry }
  let(:pizzas_chapter)   { pizzas_registry.bluebook("Pizzas") }
  let(:pizzas_hecksagon) { pizzas_registry.hecksagon("Pizzas") }
  let(:banking_registry) { boot_banking }
  let(:banking_chapter)  { banking_registry.bluebook("Banking") }

  # A SEPARATE, REAL FILE BOOT, JUST FOR THE HECKSAGON — `boot_banking`
  # above only ever `load_bluebook_files`s (the same reduced fixture
  # `pizzas_chapter`'s own header comment already warns about), so it
  # never loads `banking.hecksagon` at all and `banking_registry.
  # hecksagon("Banking")` is always nil. `bluebook`-shaped assertions
  # stay on the fast in-memory `banking_chapter` — this repo's own
  # drift-detection test already proves that chapter byte-matches a
  # full boot's for every other diagram kind — only the hecksagon needs
  # this heavier real boot to exist at all.
  let(:banking_hecksagon) { Hecks.boot(File.expand_path("../examples/banking", __dir__)).registry.hecksagon("Banking") }
  let(:scratch_chapter) { boot_scratch_with_port_routing.bluebook("Scratch") }
  let(:order)           { pizzas_chapter.aggregates.find { |a| a.hecks_name == "Order" } }

  # ── drift, across both real domains ────────────────────────────────

  # `hecksagon:` IS ONLY EVER NEEDED FOR frameworks.mmd — `bin/project_
  # diagrams` always has one in hand (`registry.hecksagon(chapter_name)`),
  # so drift detection has to hand it in too or a real frameworks.mmd on
  # disk would never match what an options-less call regenerates.
  def assert_undrifted(domain, chapter, hecksagon: nil)
    committed_dir = File.expand_path("../docs/generated/diagrams/#{domain}", __dir__)
    regenerated = Hecks::Projector.call(:diagrams, bluebook: chapter, options: { hecksagon: hecksagon })
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
    assert_undrifted("pizzas", pizzas_chapter, hecksagon: pizzas_hecksagon)
  end

  it "is exactly what bin/project_diagrams would regenerate for banking right now" do
    assert_undrifted("banking", banking_chapter, hecksagon: banking_hecksagon)
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

  # ── read models -> flowchart ─────────────────────────────────────────

  it "draws exactly one edge per aggregate_head across every real read_model in banking" do
    diagram = Hecks::Projector.call(:diagrams, bluebook: banking_chapter)["read_models.mmd"]
    declared = banking_chapter.read_models.sum { |rm| Array(rm.to_h[:aggregate_heads]).size }
    drawn = diagram.lines.count { |line| line.include?("-->") }
    expect(drawn).to eq(declared)
  end

  it "merges the same aggregate into one node across several read_models — Account feeds five in banking" do
    diagram = Hecks::Projector.call(:diagrams, bluebook: banking_chapter)["read_models.mmd"]
    account_edges = diagram.lines.count { |line| line.start_with?("    Account[(Account)]") }
    expect(account_edges).to eq(5) # CustomerPortfolio, ComplianceDashboard, DisputedPaymentCount, DisputedPaymentMedian, AccountsByKind
  end

  it "labels a count read_model and a median read_model with the shape of their own answer" do
    diagram = Hecks::Projector.call(:diagrams, bluebook: banking_chapter)["read_models.mmd"]
    expect(diagram).to include('rm_DisputedPaymentCount[["DisputedPaymentCount (count)"]]')
    expect(diagram).to include('rm_DisputedPaymentMedian[["DisputedPaymentMedian (median: amount)"]]')
  end

  it "leaves an ordinary read_model's label bare — no parenthetical for a plain row-returning view" do
    diagram = Hecks::Projector.call(:diagrams, bluebook: banking_chapter)["read_models.mmd"]
    expect(diagram).to include('rm_CustomerPortfolio[["CustomerPortfolio"]]')
  end

  # THE BUG THIS TYPE ACTUALLY HAD: an unquoted "many" label
  # (`accounts[]`) broke Mermaid's own `|label|` parser outright — the
  # `[` reads as the START OF A NEW NODE SHAPE, not text. Caught by
  # actually running the real generated output through mermaid.parse(),
  # not by eye. Pinned here so a future edit can't drop the quoting
  # without this failing.
  it "quotes a many-side edge label so its own [] doesn't break Mermaid's edge-label syntax" do
    diagram = Hecks::Projector.call(:diagrams, bluebook: banking_chapter)["read_models.mmd"]
    expect(diagram).to include('Account[(Account)] -->|"accounts[]"| rm_AccountsByKind[["AccountsByKind"]]')
    expect(diagram).not_to include("-->|accounts[]|") # the unquoted form that actually broke
  end

  it "draws no read_models.mmd for pizzas — the real corpus declares no read_model there" do
    expect(Hecks::Projector.call(:diagrams, bluebook: pizzas_chapter)["read_models.mmd"]).to be_nil
  end

  # ── surface -> flowchart ─────────────────────────────────────────────

  it "draws every one of Order's own real commands and queries in pizzas, no more and no fewer" do
    diagram = Hecks::Projector.call(:diagrams, bluebook: pizzas_chapter)["Order_surface.mmd"]
    does = diagram.lines.count { |line| line.include?("|does|") }
    asks = diagram.lines.count { |line| line.include?("|asks|") }
    expect(does).to eq(order.commands.size)
    expect(asks).to eq(order.queries.size)
  end

  it "draws a command edge solid and a query edge dotted" do
    diagram = Hecks::Projector.call(:diagrams, bluebook: pizzas_chapter)["Order_surface.mmd"]
    expect(diagram).to include('Order[(Order)] -->|does| cmd_Order_CreatePizza(["Order.CreatePizza"])')
    expect(diagram).to include('Order[(Order)] -.->|asks| qry_Order_Available{"Order.Available"}')
  end

  # A REAL, INTERESTING CASE FOUND WHILE VERIFYING, NOT INVENTED: banking's
  # own Account declares both a command AND a query named "Open" — two
  # genuinely different things (a verb versus a question) that happen to
  # share a name. The diamond/stadium shape split is what keeps that from
  # reading as one node twice.
  it "keeps a same-named command and query as two distinct nodes, distinguished by shape" do
    diagram = Hecks::Projector.call(:diagrams, bluebook: banking_chapter)["Account_surface.mmd"]
    expect(diagram).to include('cmd_Account_Open(["Account.Open"])')
    expect(diagram).to include('qry_Account_Open{"Account.Open"}')
  end

  it "generates one surface diagram per holder that declares at least one command or query, across all of banking" do
    holders_with_surface = banking_chapter.aggregates.flat_map { |a| [a, *a.entities] }
                                          .reject { |h| h.commands.empty? && h.queries.empty? }
    files = Hecks::Projector.call(:diagrams, bluebook: banking_chapter)
    surface_files = files.keys.select { |name| name.end_with?("_surface.mmd") }
    expect(surface_files.size).to eq(holders_with_surface.size)
  end

  # ── surface -> what each command writes ───────────────────────────────

  it "draws exactly one edge per real mutation Order's own commands declare, no more and no fewer" do
    diagram = Hecks::Projector.call(:diagrams, bluebook: pizzas_chapter)["Order_surface.mmd"]
    declared = order.commands.sum { |c| c.mutations.size }
    drawn = diagram.lines.count { |line| line.include?("attr_Order_") }
    expect(drawn).to eq(declared)
  end

  it "names the real argument a set/increment/decrement pulls from, in pizzas" do
    diagram = Hecks::Projector.call(:diagrams, bluebook: pizzas_chapter)["Order_surface.mmd"]
    expect(diagram).to include('cmd_Order_Purchase(["Order.Purchase"]) -->|"sets: customer_name"| attr_Order_customer_name[customer_name]')
  end

  it "states a literal source verbatim, quoted, distinct from an argument source" do
    diagram = Hecks::Projector.call(:diagrams, bluebook: pizzas_chapter)["Order_surface.mmd"]
    expect(diagram).to include("cmd_Order_Purchase([\"Order.Purchase\"]) -->|\"sets: 'sold'\"| attr_Order_status[status]")
  end

  it "names an append's own field names, not a single source, since it has none" do
    diagram = Hecks::Projector.call(:diagrams, bluebook: pizzas_chapter)["Order_surface.mmd"]
    expect(diagram).to include('cmd_Order_AddTopping(["Order.AddTopping"]) -->|"appends: name, amount"| attr_Order_toppings[toppings]')
  end

  # THE REAL, INTERESTING CASE: an increment/decrement's own argument
  # name does NOT always match its target — banking's own Account.Credit
  # increments `balance` from an `amount` argument, and LedgerEntry.Amend
  # increments `amount` from an `adjustment` argument. Naming the real
  # argument, not just the verb, is what makes that visible at all.
  it "names a real argument that doesn't share its target's own name, in banking" do
    diagram = Hecks::Projector.call(:diagrams, bluebook: banking_chapter)["Account_surface.mmd"]
    expect(diagram).to include('cmd_Account_Credit(["Account.Credit"]) -->|"increments: amount"| attr_Account_balance[balance]')
  end

  # MERGES ACROSS COMMANDS THE SAME WAY read_models.mmd MERGES ACROSS
  # read_models — real in banking: six different Account commands all
  # write `balance`, and the node merges into one rather than drawing six.
  it "merges the same attribute into one node across every command that writes it, in banking" do
    diagram = Hecks::Projector.call(:diagrams, bluebook: banking_chapter)["Account_surface.mmd"]
    balance_edges = diagram.lines.count { |line| line.include?("attr_Account_balance[balance]") }
    expect(balance_edges).to eq(6) # Credit, Debit, ApplyFee, CorrectFee, AccrueInterest, CorrectInterest
  end

  # THE BUG THIS TYPE ACTUALLY HAD: a literal value that is itself a
  # rendered value-object hash (banking's own Customer.Reinstate sets
  # `standing` to `{:value=>"good"}`) carries a double quote of its own,
  # which broke this label's outer `|"..."|` quoting outright. Caught by
  # running the real generated output through mermaid.parse(), not by
  # eye — pinned here so a future edit can't drop the fix without this
  # failing.
  it "swaps an embedded double quote in a literal value for a single quote, so it can't break the label's own quoting" do
    diagram = Hecks::Projector.call(:diagrams, bluebook: banking_chapter)["Customer_surface.mmd"]
    expect(diagram).to include("cmd_Customer_Reinstate([\"Customer.Reinstate\"]) -->|\"sets: '{:value=>'good'}'\"| attr_Customer_standing[standing]")
  end

  # A REAL, GENUINE ZERO — Order.CreatePizza declares no `sets`/
  # `increment`/`decrement`/`append` of its own at all (its own record
  # comes into being from the command's own arguments at construction,
  # not a mutation); it still gets its ordinary "does" edge, just no
  # write edge alongside it.
  it "draws no mutation edges at all for a command that genuinely declares none" do
    diagram = Hecks::Projector.call(:diagrams, bluebook: pizzas_chapter)["Order_surface.mmd"]
    expect(diagram).to include('Order[(Order)] -->|does| cmd_Order_CreatePizza(["Order.CreatePizza"])')
    expect(diagram).not_to include('cmd_Order_CreatePizza(["Order.CreatePizza"]) -->|"')
  end

  # ── sagas -> stateDiagram-v2 ───────────────────────────────────────────

  # Settlement IS THE RICH REAL CASE: a self-loop (TransferRequested fires
  # while still "requested"), a transition that dispatches TWO commands at
  # once (AccountDebited dispatches both Transfer.Debited and
  # Account.Credit), and a real compensating leg (the literal "refused"
  # trigger, not an event any aggregate announces).
  it "draws exactly one edge per real handler Settlement declares, no more and no fewer" do
    diagram = Hecks::Projector.call(:diagrams, bluebook: banking_chapter)["Settlement_saga.mmd"]
    settlement = banking_chapter.process_managers.find { |pm| pm.hecks_name == "Settlement" }

    drawn_edges = diagram.lines.map(&:strip).select { |line| line.include?("-->") && !line.start_with?("[*]") }
    expect(drawn_edges.size).to eq(settlement.handlers.size)
  end

  it "starts at the saga's own first declared state" do
    diagram = Hecks::Projector.call(:diagrams, bluebook: banking_chapter)["Settlement_saga.mmd"]
    expect(diagram).to include("[*] --> requested")
  end

  it "draws a self-loop when a handler's own from and to state are the same" do
    diagram = Hecks::Projector.call(:diagrams, bluebook: banking_chapter)["Settlement_saga.mmd"]
    expect(diagram).to include("requested --> requested: TransferRequested / dispatches Account.Debit")
  end

  it "names every command a transition dispatches, joined, when it fires more than one" do
    diagram = Hecks::Projector.call(:diagrams, bluebook: banking_chapter)["Settlement_saga.mmd"]
    expect(diagram).to include("requested --> awaiting_credit: AccountDebited / dispatches Transfer.Debited, Account.Credit")
  end

  it "states the compensating refused leg exactly as verbatim as any other trigger" do
    diagram = Hecks::Projector.call(:diagrams, bluebook: banking_chapter)["Settlement_saga.mmd"]
    expect(diagram).to include("awaiting_credit --> reversed: refused / dispatches Account.Credit, Transfer.Reverse")
  end

  it "appends no dispatches suffix when a handler dispatches nothing, in Onboarding" do
    diagram = Hecks::Projector.call(:diagrams, bluebook: banking_chapter)["Onboarding_saga.mmd"]
    expect(diagram).to include("screening --> declined: OnboardingDeclined")
    expect(diagram).not_to include("OnboardingDeclined /")
  end

  it "generates one saga diagram per real process_manager, across all of banking" do
    files = Hecks::Projector.call(:diagrams, bluebook: banking_chapter)
    saga_files = files.keys.select { |name| name.end_with?("_saga.mmd") }
    expect(saga_files).to contain_exactly("Onboarding_saga.mmd", "Settlement_saga.mmd", "ExternalSettlement_saga.mmd")
  end

  it "draws no saga diagram at all for pizzas — the real corpus declares no process_manager there" do
    files = Hecks::Projector.call(:diagrams, bluebook: pizzas_chapter)
    expect(files.keys).not_to include(a_string_ending_with("_saga.mmd"))
  end

  # ── frameworks -> flowchart ────────────────────────────────────────

  # THE REAL, RICH CASE: banking attaches two frameworks AND reaches
  # across into two more domains — Compliance (twice, from two separate
  # policies) and Notifications, a domain that isn't a framework member
  # at all, proving this draws every real cross-domain dependency, not
  # just the three named in Hecks::Framework.members.
  it "draws exactly one edge per real uses_framework and one per distinct cross-domain policy target, in banking" do
    diagram = Hecks::Projector.call(:diagrams, bluebook: banking_chapter,
                                               options:  { hecksagon: banking_hecksagon })["frameworks.mmd"]
    attaches = diagram.lines.count { |line| line.include?("|attaches|") }
    reaches = diagram.lines.count { |line| line.include?("|reaches across|") }

    expect(attaches).to eq(banking_hecksagon.framework_members.size)
    expect(reaches).to eq(banking_chapter.policies.filter_map(&:target_domain).uniq.size)
  end

  it "draws attaches dotted and reaches across solid, and dedupes two policies reaching the same domain" do
    diagram = Hecks::Projector.call(:diagrams, bluebook: banking_chapter,
                                               options:  { hecksagon: banking_hecksagon })["frameworks.mmd"]
    expect(diagram).to include("Banking[(Banking)] -.->|attaches| Governance[(Governance)]")
    expect(diagram).to include("Banking[(Banking)] -.->|attaches| Identity[(Identity)]")
    expect(diagram).to include("Banking[(Banking)] -->|reaches across| Compliance[(Compliance)]")
    expect(diagram.lines.count { |line| line.include?("|reaches across| Compliance") }).to eq(1) # ReviewOnFreeze AND ReviewOnBoxSurrender both target it
  end

  it "generates a real, non-empty frameworks.mmd for pizzas too — attaches Governance, reaches across nothing" do
    diagram = Hecks::Projector.call(:diagrams, bluebook: pizzas_chapter,
                                               options:  { hecksagon: pizzas_hecksagon })["frameworks.mmd"]
    expect(diagram).to include("Pizzas[(Pizzas)] -.->|attaches| Governance[(Governance)]")
    expect(diagram).not_to include("reaches across")
  end

  # NO hecksagon HANDED IN — an older caller, or a spec fixture that
  # doesn't need one — MEANS NO frameworks.mmd, the same "nothing to
  # state" skip every other diagram in this file already takes when its
  # own data is empty, not an error.
  it "draws no frameworks.mmd at all when no hecksagon is given" do
    expect(Hecks::Projector.call(:diagrams, bluebook: banking_chapter)["frameworks.mmd"]).to be_nil
  end

  # A STRUCTURAL CHECK, NOT A MERMAID PARSE — this repo's own suite takes
  # no Node/npm dependency for that. Every diagram this projection can
  # currently produce (all 41, across both real domains plus the one
  # in-memory to: fixture) WAS run through the real mermaid.parse()
  # engine once, by hand, to confirm this exact shape is valid Mermaid
  # — this just guards the one structural fact that made that true for
  # each kind: the diagram type declaration is the first non-comment
  # line.
  it "is shaped like real Mermaid in every generated file — the diagram type declared first" do
    expectations = {
      [:pizzas_chapter, "Order_lifecycle.mmd"]  => "stateDiagram-v2",
      [:pizzas_chapter, "dispatch.mmd"]         => "flowchart LR",
      [:pizzas_chapter, "roles.mmd"]            => "flowchart LR",
      [:pizzas_chapter, "ports.mmd"]            => "flowchart LR",
      [:pizzas_chapter, "Order_surface.mmd"]    => "flowchart LR",
      [:pizzas_chapter, "frameworks.mmd"]       => "flowchart LR",
      [:banking_chapter, "relationships.mmd"]   => "erDiagram",
      [:banking_chapter, "dispatch.mmd"]        => "flowchart LR",
      [:banking_chapter, "roles.mmd"]           => "flowchart LR",
      [:banking_chapter, "read_models.mmd"]     => "flowchart LR",
      [:banking_chapter, "Account_surface.mmd"] => "flowchart LR",
      [:banking_chapter, "Settlement_saga.mmd"] => "stateDiagram-v2",
      [:banking_chapter, "frameworks.mmd"]      => "flowchart LR",
      [:scratch_chapter, "ports.mmd"]           => "flowchart LR"
    }
    hecksagons = { pizzas_chapter: -> { pizzas_hecksagon }, banking_chapter: -> { banking_hecksagon } }

    expectations.each do |(chapter_method, filename), expected_first_line|
      hecksagon = hecksagons[chapter_method]&.call
      files = Hecks::Projector.call(:diagrams, bluebook: send(chapter_method), options: { hecksagon: hecksagon })
      lines = files.fetch(filename).lines.map(&:strip).reject(&:empty?)
      first_real_line = lines.find { |line| !line.start_with?("%%") }
      expect(first_real_line).to eq(expected_first_line), "#{filename}: expected #{expected_first_line.inspect} first"
    end
  end
end
