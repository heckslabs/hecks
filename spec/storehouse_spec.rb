require "spec_helper"
require "hecks/ports/persistence/plugins/era"

# THE STOREHOUSE BUS — dispatch/query/state/catalog/describe/validate/...,
# projected off the SAME machinery `CliRunner`/`Facade::JsonDoor` already
# use, so these specs prove composition rather than re-deriving verb
# resolution or JSON materialization from scratch. `bin/hecks_mcp_door`
# is one MCP-over-stdio door onto this bus, not the bus itself.
RSpec.describe Hecks::Storehouse do
  # THE BUS'S OWN AUDIT LOG IS REAL DISK STATE, keyed only by domain name
  # ("Pizzas") — every example in this file that dispatches/queries/reads
  # state against `runtime` writes to the SAME file regardless of which
  # example it is, since a fresh in-memory `runtime` per example is not a
  # fresh log. Wiped before every example so `.follow`'s own assertions
  # never depend on run order or on what an earlier example happened to log.
  before { FileUtils.rm_rf(described_class::LOG_ROOT) }

  let(:runtime) { boot_in_memory }
  let(:pizza_args) do
    { name: { value: "Margherita" }, pizza: { price_cents: { cents: 1200 }, size: { value: "large" } } }
  end

  describe ".dispatch" do
    it "issues the command and answers the record's id, state, and events" do
      result = described_class.dispatch(runtime: runtime, command: "create_pizza",
                                        summary: "spec", args: pizza_args)

      expect(result[:ok]).to be true
      expect(result[:id]).to eq("Margherita")
      expect(result[:state][:status]).to eq("available")
      expect(result[:events].map { |e| e[:name] }).to eq(["PizzaCreated"])
    end

    it "resolves the qualified form identically to the short form" do
      short      = described_class.dispatch(runtime: runtime, command: "create_pizza",
                                            summary: "spec", args: pizza_args)
      qualified  = described_class.dispatch(runtime: runtime, command: "order.create_pizza", summary: "spec",
                                            args: pizza_args.merge(name: { value: "Diavola" }))

      expect(short[:ok]).to be true
      expect(qualified[:ok]).to be true
    end

    it "refuses a summary-less call rather than dispatching" do
      result = described_class.dispatch(runtime: runtime, command: "create_pizza", summary: "", args: pizza_args)

      expect(result[:ok]).to be false
      expect(result[:error]).to include("summary")
      expect(runtime.events).to be_empty
    end

    it "answers a structured refusal, not a raised error, for an unknown command" do
      result = described_class.dispatch(runtime: runtime, command: "no_such_command", summary: "spec")

      expect(result[:ok]).to be false
      expect(result[:summary]).to eq("spec")
      expect(result[:error]).to include("no such command")
    end

    it "answers a structured refusal for a domain rule violation" do
      described_class.dispatch(runtime: runtime, command: "create_pizza", summary: "spec", args: pizza_args)
      described_class.dispatch(runtime: runtime, command: "order.add_topping", summary: "spec",
                               args: { to: "Margherita", topping: { value: "Basil" }, amount: { value: 1 } })
      purchase_args = { to: "Margherita", amount: { cents: 1200 }, customer_name: { value: "Alex" } }
      sold           = described_class.dispatch(runtime: runtime, command: "order.purchase", summary: "spec",
                                                args: purchase_args)
      purchase_again = described_class.dispatch(runtime: runtime, command: "order.purchase", summary: "spec",
                                                args: purchase_args)

      expect(sold[:ok]).to be true
      expect(purchase_again[:ok]).to be false
      expect(purchase_again[:error]).to be_a(String)
    end
  end

  describe ".query" do
    it "answers the declared question's rows" do
      described_class.dispatch(runtime: runtime, command: "create_pizza", summary: "spec", args: pizza_args)

      result = described_class.query(runtime: runtime, question: "available", summary: "spec")

      expect(result[:ok]).to be true
      expect(result[:rows].map { |row| row[:id] }).to eq(["Margherita"])
    end

    it "refuses an unknown question" do
      result = described_class.query(runtime: runtime, question: "no_such_question", summary: "spec")

      expect(result[:ok]).to be false
      expect(result[:error]).to include("no such query")
    end
  end

  describe ".state" do
    before { described_class.dispatch(runtime: runtime, command: "create_pizza", summary: "spec", args: pizza_args) }

    it "answers every record when id is omitted" do
      result = described_class.state(runtime: runtime, aggregate: "Order", summary: "spec")

      expect(result[:ok]).to be true
      expect(result[:count]).to eq(1)
      expect(result[:records].first[:id]).to eq("Margherita")
    end

    it "answers one record when id is given" do
      result = described_class.state(runtime: runtime, aggregate: "Order", id: "Margherita", summary: "spec")

      expect(result[:ok]).to be true
      expect(result[:record][:id]).to eq("Margherita")
    end

    it "refuses an id that names no record" do
      result = described_class.state(runtime: runtime, aggregate: "Order", id: "Nope", summary: "spec")

      expect(result[:ok]).to be false
      expect(result[:error]).to include("no Order found")
    end

    it "refuses an aggregate the domain never declared" do
      result = described_class.state(runtime: runtime, aggregate: "Calzone", summary: "spec")

      expect(result[:ok]).to be false
      expect(result[:error]).to include("declares no aggregate")
    end
  end

  describe ".catalog" do
    it "lists every aggregate and the commands/queries each answers to" do
      result = described_class.catalog(runtime: runtime)

      expect(result[:ok]).to be true
      expect(result[:domain]).to eq("Pizzas")
      order = result[:aggregates].find { |a| a[:name] == "Order" }
      expect(order[:commands]).to include("create_pizza!", "purchase!")
      expect(order[:queries]).to include("available")
    end
  end

  describe ".describe" do
    it "answers the whole chapter's usage document when aggregate is omitted" do
      result = described_class.describe(runtime: runtime)

      expect(result[:ok]).to be true
      expect(result[:docs]).to include("Order")
    end

    it "narrows to one aggregate's contract" do
      result = described_class.describe(runtime: runtime, aggregate: "Order")

      expect(result[:ok]).to be true
      expect(result[:docs]).to include("CreatePizza")
    end

    it "refuses an aggregate the domain never declared" do
      result = described_class.describe(runtime: runtime, aggregate: "Calzone")

      expect(result[:ok]).to be false
      expect(result[:error]).to include("declares no aggregate")
    end
  end

  describe ".validate" do
    it "answers valid: true for a domain whose wiring boots cleanly" do
      result = described_class.validate(domain: "examples/pizzas")

      expect(result).to eq(ok: true, domain: "examples/pizzas", valid: true)
    end

    it "answers valid: false, never a raised error, for a domain that cannot boot" do
      result = described_class.validate(domain: "examples/no_such_domain")

      expect(result[:ok]).to be false
      expect(result[:valid]).to be false
      expect(result[:error]).to be_a(String)
    end

    it "runs the static model checker and reports findings when deep: true" do
      result = described_class.validate(domain: "examples/pizzas", deep: true)

      expect(result[:ok]).to be true
      expect(result[:findings]).to be_an(Array)
    end

    it "answers no findings key at all when deep is omitted" do
      result = described_class.validate(domain: "examples/pizzas")

      expect(result).not_to have_key(:findings)
    end
  end

  describe ".dispatch with dry_run: true" do
    it "answers would_succeed: true and persists nothing" do
      result = described_class.dispatch(runtime: runtime, command: "create_pizza", summary: "spec",
                                        args: pizza_args, dry_run: true)

      expect(result).to eq(ok: true, summary: "spec", would_succeed: true)
      expect(described_class.state(runtime: runtime, aggregate: "Order", summary: "spec")[:count]).to eq(0)
    end

    it "answers would_succeed: false with the domain's own refusal text, for a real domain rule" do
      result = described_class.dispatch(runtime: runtime, command: "order.purchase", summary: "spec",
                                        dry_run: true,
                                        args: { to: "Margherita", amount: { cents: 1200 },
                                                 customer_name: { value: "Alex" } })

      expect(result[:ok]).to be true
      expect(result[:would_succeed]).to be false
      expect(result[:error]).to be_a(String)
    end

    it "still answers ok: false for a request that never reaches the domain at all" do
      result = described_class.dispatch(runtime: runtime, command: "no_such_command", summary: "spec",
                                        dry_run: true)

      expect(result[:ok]).to be false
      expect(result).not_to have_key(:would_succeed)
    end
  end

  describe ".dispatch with source:" do
    it "accepts a declared source tag" do
      result = described_class.dispatch(runtime: runtime, command: "create_pizza", summary: "spec",
                                        args: pizza_args, source: "operator")

      expect(result[:ok]).to be true
    end

    it "refuses a source tag outside the closed set" do
      result = described_class.dispatch(runtime: runtime, command: "create_pizza", summary: "spec",
                                        args: pizza_args, source: "not-a-real-source")

      expect(result[:ok]).to be false
      expect(result[:error]).to include("source")
      expect(runtime.events).to be_empty
    end
  end

  describe ".dispatch_batch" do
    it "runs every step and reports ok: true only when all of them succeeded" do
      described_class.dispatch(runtime: runtime, command: "create_pizza", summary: "spec", args: pizza_args)

      result = described_class.dispatch_batch(
        runtime: runtime, summary: "spec",
        steps: [{ command: "order.add_topping",
                  args:    { to: "Margherita", topping: { value: "Basil" }, amount: { value: 1 } } }]
      )

      expect(result[:ok]).to be true
      expect(result[:results].length).to eq(1)
      expect(result[:results].first[:ok]).to be true
    end

    it "runs every step even after an earlier one refuses, and reports ok: false overall" do
      result = described_class.dispatch_batch(
        runtime: runtime, summary: "spec",
        steps: [{ command: "no_such_command", args: {} },
                { command: "create_pizza", args: pizza_args }]
      )

      expect(result[:ok]).to be false
      expect(result[:results].map { |r| r[:ok] }).to eq([false, true])
    end
  end

  describe ".domains" do
    it "lists every real example domain under the default root" do
      result = described_class.domains

      expect(result[:ok]).to be true
      expect(result[:domains]).to include("examples/pizzas", "examples/banking")
    end

    it "answers an empty list, not an error, for a root that doesn't exist" do
      result = described_class.domains(under: "examples/no_such_root")

      expect(result).to eq(ok: true, under: "examples/no_such_root", domains: [])
    end
  end

  describe ".history" do
    it "answers every append-only journal entry, not just current state" do
      described_class.dispatch(runtime: runtime, command: "create_pizza", summary: "spec", args: pizza_args)
      described_class.dispatch(runtime: runtime, command: "order.add_topping", summary: "spec",
                               args: { to: "Margherita", topping: { value: "Basil" }, amount: { value: 1 } })

      result = described_class.history(runtime: runtime)

      expect(result[:ok]).to be true
      expect(result[:history]["order"].length).to eq(2)
      expect(result[:history]["order"].map { |entry| entry[:operation] }).to eq(%w[save save])
    end
  end

  describe ".behaviors" do
    it "runs a domain's real .behaviors suite and reports pass/fail per test" do
      result = described_class.behaviors(target: "examples/pizzas")

      expect(result[:ok]).to be true
      expect(result[:counts][:total]).to be > 0
      expect(result[:counts][:failed]).to eq(0)
      expect(result[:counts][:errored]).to eq(0)
    end

    it "refuses a target that names no file or directory" do
      result = described_class.behaviors(target: "examples/no_such_target")

      expect(result[:ok]).to be false
      expect(result[:error]).to include("no such file or directory")
    end
  end

  describe ".follow" do
    it "answers no entries for a domain nothing has dispatched against yet" do
      result = described_class.follow(runtime: runtime)

      expect(result).to eq(ok: true, domain: "Pizzas", entries: [])
    end

    it "tails dispatch/query/state calls made through this door, in order" do
      described_class.dispatch(runtime: runtime, command: "create_pizza", summary: "one", args: pizza_args,
                               source: "operator")
      described_class.query(runtime: runtime, question: "available", summary: "two")
      described_class.state(runtime: runtime, aggregate: "Order", summary: "three")

      result = described_class.follow(runtime: runtime)

      expect(result[:ok]).to be true
      expect(result[:entries].map { |e| e[:tool] }).to eq(%w[dispatch query state])
      expect(result[:entries].map { |e| e[:summary] }).to eq(%w[one two three])
      expect(result[:entries].first[:source]).to eq("operator")
      expect(result[:entries].first[:ok]).to be true
    end

    it "respects limit, keeping the most recent entries" do
      3.times { |n| described_class.query(runtime: runtime, question: "available", summary: "q#{n}") }

      result = described_class.follow(runtime: runtime, limit: 2)

      expect(result[:entries].map { |e| e[:summary] }).to eq(%w[q1 q2])
    end

    it "records a refused call too, not only a successful one" do
      described_class.dispatch(runtime: runtime, command: "no_such_command", summary: "spec")

      result = described_class.follow(runtime: runtime)

      expect(result[:entries].last[:ok]).to be false
      expect(result[:entries].last[:error]).to be_a(String)
    end
  end

  describe ".dispatch with role:/actor_id:" do
    it "checks a role-gated command against the bound caller, by string equality" do
      wrong = described_class.dispatch(runtime: runtime, command: "create_pizza", summary: "spec",
                                       args: pizza_args, role: "Visitor")
      right = described_class.dispatch(runtime: runtime, command: "create_pizza", summary: "spec",
                                       args: pizza_args, role: "Chef")

      expect(wrong[:ok]).to be false
      expect(wrong[:error]).to match(/role/i)
      expect(right[:ok]).to be true
    end

    it "leaves a command that declares no role unaffected by an unrelated role binding" do
      result = described_class.query(runtime: runtime, question: "available", summary: "spec", role: "Chef")

      expect(result[:ok]).to be true
    end

    it "refuses actor_id given without role" do
      result = described_class.dispatch(runtime: runtime, command: "create_pizza", summary: "spec",
                                        args: pizza_args, actor_id: "u1")

      expect(result[:ok]).to be false
      expect(result[:error]).to include("actor_id")
      expect(runtime.events).to be_empty
    end

    it "records role/actor_id on the audit log line, win or refuse" do
      described_class.dispatch(runtime: runtime, command: "create_pizza", summary: "spec",
                               args: pizza_args, role: "Chef")

      entry = described_class.follow(runtime: runtime)[:entries].first
      expect(entry[:role]).to eq("Chef")
    end

    # `boot_in_memory`'s fixture attaches Governance but binds no real
    # authorization ADAPTER — an `actor_id` alongside `role` reaches for
    # a live `Governance::RoleAssignment` lookup through one
    # (`CommandRules::Authorization`'s own header), which is genuinely
    # unanswerable here. `Runtime::WiringError` is the honest result;
    # this proves it comes back as a structured refusal — role/actor_id
    # STILL recorded on the log line — never a raised error crossing
    # this door, the same promise every other refusal here keeps.
    it "answers a structured refusal, not a raised error, when no authorization adapter can answer actor_id" do
      result = described_class.dispatch(runtime: runtime, command: "create_pizza", summary: "spec",
                                        args: pizza_args, role: "Chef", actor_id: "u1")

      expect(result[:ok]).to be false
      expect(result[:error]).to be_a(String)

      entry = described_class.follow(runtime: runtime)[:entries].first
      expect(entry[:role]).to eq("Chef")
      expect(entry[:actor_id]).to eq("u1")
      expect(entry[:ok]).to be false
    end
  end

  describe ".events" do
    it "answers no events for a domain nothing has dispatched against yet" do
      result = described_class.events(runtime: runtime)

      expect(result).to eq(ok: true, domain: "Pizzas", events: [])
    end

    it "answers the events a real dispatch announced, sourced from this door's own audit log" do
      described_class.dispatch(runtime: runtime, command: "create_pizza", summary: "spec", args: pizza_args)

      result = described_class.events(runtime: runtime, aggregate: "Order", id: "Margherita")

      expect(result[:ok]).to be true
      expect(result[:events].map { |e| e[:name] }).to eq(["PizzaCreated"])
      expect(result[:events].first[:id]).to eq("Margherita")
    end

    it "answers nothing for a dry run — nothing was actually announced" do
      described_class.dispatch(runtime: runtime, command: "create_pizza", summary: "spec", args: pizza_args,
                               dry_run: true)

      result = described_class.events(runtime: runtime, aggregate: "Order")

      expect(result[:events]).to eq([])
    end

    it "answers nothing for an id that named no dispatch" do
      described_class.dispatch(runtime: runtime, command: "create_pizza", summary: "spec", args: pizza_args)

      result = described_class.events(runtime: runtime, aggregate: "Order", id: "Nope")

      expect(result[:events]).to eq([])
    end

    it "refuses id: without aggregate:" do
      result = described_class.events(runtime: runtime, id: "Margherita")

      expect(result[:ok]).to be false
      expect(result[:error]).to include("aggregate")
    end

    it "refuses an aggregate the domain never declared" do
      result = described_class.events(runtime: runtime, aggregate: "Calzone")

      expect(result[:ok]).to be false
      expect(result[:error]).to include("declares no aggregate")
    end
  end
end
