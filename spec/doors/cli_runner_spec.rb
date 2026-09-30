require "spec_helper"

# The runner behind a projected CLI: returns text plus a status, printing and exiting
# nothing. Run against pizzas so nothing passes by knowing its own chapter.
RSpec.describe Hecks::Doors::CliRunner do
  let(:runtime) { boot_in_memory }

  def run(*argv) = described_class.call(runtime: runtime, argv: argv, program: "bin/run")
  def text(*argv) = run(*argv).first
  def status(*argv) = run(*argv).last

  def a_pizza(name = "Margherita")
    run("order.create_pizza", "name=#{name}", "pizza.price_cents.cents=1200", "pizza.size.value=large")
  end

  def banking_runtime
    registry = Hecks::Runtime::Registry.new
    Hecks.with_registry(registry) do
      Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
      Kernel.load(InMemoryDomain::EXTRACTION_PORT)
      Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
      Kernel.load(InMemoryDomain::PRISM_ADAPTER)
      load_bluebook_files(InMemoryDomain::BANKING_BLUEBOOK_DIR)
      Hecks.hecksagon("Banking") do
        uses_framework "Governance"
        Banking::Customer.persisted_by("Memory")
        Banking::SafeDepositBox.persisted_by("Memory")
      end
      Hecks.hecksagon("Governance") do
        Governance::RoleAssignment.persisted_by("Memory")
        Governance::RoleTransition.persisted_by("Memory")
      end
    end
    registry.verify!
    Hecks::Runtime::Loader.bind_runtime(Hecks::Runtime::Dispatcher.new(registry))
  end

  describe "the usage" do
    it "answers with the projected surface when asked for nothing" do
      expect(text).to include("Pizzas —")
      expect(text).to include("create_pizza")
      expect(status).to eq(0)
    end

    it "answers one verb's help without dispatching it" do
      expect(text("order.create_pizza", "--help")).to include("dispatches Pizzas::Order.CreatePizza")
      expect(runtime.events).to be_empty
    end
  end

  # Both spellings reach the same verb.
  describe "routing to another chapter" do
    it "speaks to a chapter the domain attaches when the first word names it" do
      output, code = run("governance")

      expect(code).to eq(0)
      expect(output).to start_with("Governance").and include("bin/run governance <verb>")
    end

    it "keeps to the domain's own chapter otherwise" do
      output, = run
      expect(output).not_to start_with("Governance")
    end
  end

  describe "naming" do
    it "takes the short form when no other aggregate declares that verb" do
      expect(run("create_pizza", "name=X", "pizza.price_cents.cents=900", "pizza.size.value=small").last).to eq(0)
    end

    it "still takes the aggregate-qualified form" do
      expect(run("order.create_pizza", "name=Y", "pizza.price_cents.cents=900", "pizza.size.value=small").last).to eq(0)
    end
  end

  describe "dispatching" do
    it "answers the record it made, with the events it emitted" do
      output, code = a_pizza

      expect(code).to eq(0)
      answer = JSON.parse(output)
      expect(answer["id"]).to eq("Margherita")
      expect(answer["events"]).to eq(["PizzaCreated"])
      expect(answer.dig("state", "pizza", "price_cents", "cents")).to eq(1200)
    end

    it "reaches an existing record through a bare word, the verb's first argument" do
      a_pizza
      output, code = run("order.add_topping", "Margherita", "topping=Basil", "amount=3")

      expect(code).to eq(0)
      expect(JSON.parse(output).dig("state", "toppings").length).to eq(1)
    end

    it "reaches an existing record through id" do
      a_pizza
      output, code = run("order.add_topping", "id=Margherita", "topping=Basil", "amount=3")

      expect(code).to eq(0)
      expect(JSON.parse(output).dig("state", "toppings").length).to eq(1)
    end

    it "routes SafeDepositBox.Visit.Annotate with aggregate and entity receivers outside its facts" do
      banking = banking_runtime
      banking.dispatch_flat("Banking::Customer.Register", reference: { value: "c" },
                       name: { given: "A", family: "Customer" }, email: { address: "a@example.com" })
      banking.dispatch_flat("Banking::SafeDepositBox.Rent", customer: "c", branch_code: { value: "DOWNTOWN" },
                                                       box_number: { value: 12 }, size: { value: "medium" })
      banking.dispatch_flat("Banking::SafeDepositBox.LogVisit", branch_code: { value: "DOWNTOWN" },
                                                           box_number: { value: 12 },
                                                           date: { value: "2026-01-05" }, sequence: { value: 1 })

      output, code = described_class.call(
        runtime: banking,
        argv:    ["safe_deposit_box.visit.annotate", "to.aggregate=DOWNTOWN:12",
                  "to.entity=2026-01-05:1", "note.text=Flagged"],
        program: "bin/run"
      )

      expect(code).to eq(0), output
      expect(Banking::SafeDepositBox.find("DOWNTOWN:12").visits.first[:note].to_h).to eq(text: "Flagged")
    end
  end

  # A reaction a domain's own given refused is on the dispatch result; the answer names it.
  describe "reactions a domain refused" do
    def result_with(refused)
      Hecks::Runtime::Dispatcher::Result.new(verb: "D::A.Go", instance: nil, events: [],
                                             refused_reactions: refused)
    end

    it "names each refusal the dispatch result carries" do
      refused = [{ policy: "Refused", trigger: "D::Admit", reason: "Admit refused — a given" }]

      expect(described_class.refused_answer(result_with(refused))).to eq(refused_reactions: refused)
    end

    it "adds nothing when every reaction was delivered, or the result carries no reaction log" do
      expect(described_class.refused_answer(result_with([]))).to eq({})
      expect(described_class.refused_answer(Struct.new(:events).new([]))).to eq({})
    end

    it "blocks --wait on a refusal with no alternative, not on a given-gated pair's declined half" do
      delivered = { policy: "Match", on: "Answered", trigger: "D::Cmp.Match", delivered: true }
      declined  = { policy: "Drift", on: "Answered", trigger: "D::Cmp.Drift", delivered: false, reason: "no" }
      alone     = { policy: "Accept", on: "Examined", trigger: "D::Run.Accept", delivered: false, reason: "no" }
      defect    = alone.merge(defect: true)
      blocking  = ->(entries) { Hecks::Runtime::ReactionOutcome.blocking(entries).map { |r| r[:trigger] } }

      expect(blocking.call([delivered, declined])).to eq([])
      expect(blocking.call([delivered, declined, alone])).to eq(["D::Run.Accept"])
      expect(blocking.call([defect])).to eq([])
      exists = alone.merge(trigger: "D::Tenant.Register",
                           reason:  "Register creates a Tenant that already exists — slug.value \"a\"")
      expect(blocking.call([exists])).to eq([])
      expect(blocking.call([alone.merge(on: "Other"), delivered, declined])).to eq(["D::Run.Accept"])
    end

    it "fails --wait on a reaction that crashed, and shows the defect" do
      defect = { policy: "Boom", on: "Went", trigger: "D::A.Next", delivered: false,
                 reason: "undefined method", defect: true, error_class: "NoMethodError" }
      shown  = defect.slice(:policy, :trigger, :reason, :error_class)
      found  = Hecks::Runtime::ReactionOutcome.defects([defect])
      handle = Hecks::Runtime::Dispatcher::Result.new(verb: "D::A.Go", instance: nil, events: [],
                                                      reaction_defects: found)
      text, status, reason = described_class.settled(nil, { verb: "D::A.Go" }, handle, nil, nil,
                                                     described_class.refused_answer(handle))

      expect(Hecks::Runtime::ReactionOutcome.blocking([defect])).to eq([])
      expect(status).to eq(1)
      expect(reason).to eq("reaction Boom crashed (NoMethodError): undefined method")
      expect(JSON.parse(text)["reaction_defects"]).to eq([JSON.parse(JSON.generate(shown))])
    end

    it "leaves a dispatch that caused no refusal answered exactly as before" do
      expect(JSON.parse(a_pizza.first)).not_to have_key("refused_reactions")
    end
  end

  describe "text_answer" do
    it "prints one row raw only for a query declared to return a Document" do
      expect(described_class.text_answer({ returns: "Document" }, [{ text: "# Title" }])).to eq("# Title")
      expect(described_class.text_answer({ returns: "Note" }, [{ text: "one" }])).to be_nil
      expect(described_class.text_answer({ returns: "Note" }, [{ text: "one" }, { text: "two" }])).to be_nil
      expect(described_class.text_answer({ returns: nil }, [{ text: "one" }])).to be_nil
    end
  end

  describe "asking" do
    it "answers rows, materialised out of their value objects" do
      a_pizza("Bare")
      output, code = run("ask", "order.available")

      expect(code).to eq(0)
      expect(JSON.parse(output).map { |row| row.dig("name", "value") }).to include("Bare")
    end

    it "answers a question by its bare name when no command shares it" do
      a_pizza("Bare")
      output, code = run("available")

      expect(code).to eq(0)
      expect(JSON.parse(output).map { |row| row.dig("name", "value") }).to include("Bare")
    end

    it "changes nothing" do
      a_pizza
      before = runtime.events.length
      run("ask", "order.available")

      expect(runtime.events.length).to eq(before)
    end
  end

  # A refusal carries the chapter's own sentence and a status a script can branch on.
  describe "refusing" do
    it "hands back the domain's own wording, and a non-zero status" do
      a_pizza
      output, code = run("order.purchase", "id=Margherita", "customer_name=Chris", "amount.cents=1200")

      expect(code).to eq(1)
      expect(output).to match(/topping/i)
    end

    it "names an argument the verb does not take, and points at its help" do
      output, code = run("order.create_pizza", "nmae=Margherita")

      expect(code).to eq(1)
      expect(output).to include(%(no argument "nmae"))
      expect(output).to include("bin/run order.create_pizza --help")
    end

    it "refuses a value the declared type cannot hold" do
      output, code = run("order.create_pizza", "name=X", "pizza.price_cents.cents=lots", "pizza.size.value=large")

      expect(code).to eq(1)
      expect(output).to include("is not Integer")
    end

    it "suggests what a misspelling nearly named" do
      output, code = run("order.create_piza")

      expect(code).to eq(1)
      expect(output).to include("no such verb: order.create_piza")
      expect(output).to include("did you mean")
      expect(output).to include("order.create_pizza")
    end

    it "keeps questions and verbs apart when refusing" do
      expect(text("ask", "order.create_pizza")).to include("no such question")
    end
  end
end
