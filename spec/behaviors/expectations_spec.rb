require "hecks/behaviors/expectations"

RSpec.describe Hecks::Behaviors::Expectations do
  let(:root) { File.join(InMemoryDomain::ROOT, "examples/pizzas/bluebook") }
  let(:memory_hecksagon) { File.join(InMemoryDomain::ROOT, "examples/pizzas/pizzas_behaviors.hecksagon") }
  let(:runtime) { Hecks.boot_files([File.join(root, "pizzas.bluebook"), memory_hecksagon], install_facade: false) }
  let(:bluebooks) { runtime.registry.bluebooks.values }

  describe ".qualify" do
    it "passes a dotted name through as a literal FQN" do
      expect(described_class.qualify("Pizzas::Order.CreatePizza", nil, bluebooks, kind: :command))
        .to eq("Pizzas::Order.CreatePizza")
    end

    it "resolves a bare command name to its declaring aggregate" do
      expect(described_class.qualify("CreatePizza", nil, bluebooks, kind: :command))
        .to eq("Pizzas::Order.CreatePizza")
    end

    it "resolves a bare query name to its declaring aggregate" do
      expect(described_class.qualify("Available", nil, bluebooks, kind: :query))
        .to eq("Pizzas::Order.Available")
    end

    it "narrows the search with on: when given" do
      expect(described_class.qualify("CreatePizza", "Order", bluebooks, kind: :command))
        .to eq("Pizzas::Order.CreatePizza")
    end

    it "raises naming the command when no aggregate declares it" do
      expect { described_class.qualify("NoSuchVerb", nil, bluebooks, kind: :command) }
        .to raise_error(ArgumentError, /no aggregate.*declares a command named "NoSuchVerb"/)
    end
  end

  describe ".normalize" do
    it "treats a bare scalar and a wrapped value object as equal" do
      value_object = runtime.registry.bluebook("Pizzas").aggregate("Order").value_object("PizzaName")
      wrapped = Hecks::Runtime::Value.new(value_object, { value: "Margherita" })

      expect(described_class.normalize(wrapped)).to eq(described_class.normalize({ value: "Margherita" }))
      expect(described_class.normalize({ value: "Margherita" })).to eq(described_class.normalize("Margherita"))
    end
  end

  describe "refused: matching" do
    let(:suite) { Hecks::Behaviors::BehaviorsSuite.new(loads: [File.join(root, "pizzas.bluebook"), memory_hecksagon]) }

    def test_case(tests_command:, on_aggregate:, input:, expect:, setups: [])
      Hecks::Behaviors::TestCase.new(description: "t", tests_command: tests_command, on_aggregate: on_aggregate,
                                     kind: :command, setups: setups, input: input, expect: expect)
    end

    it "passes ok: true for a command that succeeds" do
      test = test_case(tests_command: "CreatePizza", on_aggregate: "Order",
                       input: { name: { value: "Ok" }, pizza: { price_cents: { cents: 900 }, size: { value: "small" } } },
                       expect: { ok: true })
      expect(described_class.run_one(test, suite).status).to eq(:pass)
    end

    it "passes when the refusal message includes the expected substring" do
      test = test_case(tests_command: "AddTopping", on_aggregate: "Order",
                       setups: [Hecks::Behaviors::TestSetup.new(
                         command: "CreatePizza",
                         args:    { name: { value: "Sealed" }, pizza: { price_cents: { cents: 900 }, size: { value: "small" } } }
                       )],
                       input: { name: "Sealed", topping: { value: "Basil" }, amount: { value: 0 } },
                       expect: { refused: "an amount is positive" })
      run = described_class.run_one(test, suite)
      expect(run.status).to eq(:pass)
    end

    it "fails when the refusal happened but the message doesn't match, showing both" do
      test = test_case(tests_command: "AddTopping", on_aggregate: "Order",
                       setups: [Hecks::Behaviors::TestSetup.new(
                         command: "CreatePizza",
                         args:    { name: { value: "Sealed2" }, pizza: { price_cents: { cents: 900 }, size: { value: "small" } } }
                       )],
                       input: { name: "Sealed2", topping: { value: "Basil" }, amount: { value: 0 } },
                       expect: { refused: "a sold pizza cannot be changed" })
      run = described_class.run_one(test, suite)
      expect(run.status).to eq(:fail)
      expect(run.message).to include("an amount is positive")
    end

    it "fails when expect refused: is set but the dispatch actually succeeded" do
      test = test_case(tests_command: "CreatePizza", on_aggregate: "Order",
                       input: { name: { value: "Succeeds" }, pizza: { price_cents: { cents: 900 }, size: { value: "small" } } },
                       expect: { refused: "anything" })
      run = described_class.run_one(test, suite)
      expect(run.status).to eq(:fail)
      expect(run.message).to include("dispatch succeeded")
    end
  end
end
