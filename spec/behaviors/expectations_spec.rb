require "tmpdir"
require "fileutils"
require "hecks/behaviors/expectations"

RSpec.describe Hecks::Behaviors::Expectations do
  let(:root) { File.join(InMemoryDomain::ROOT, "examples/pizzas/bluebook") }
  let(:memory_hecksagon) { File.join(InMemoryDomain::ROOT, "examples/pizzas/pizzas_behaviors.hecksagon") }
  let(:runtime) { Hecks.boot_files([File.join(root, "pizzas.bluebook"), memory_hecksagon], install_doors: false) }
  let(:bluebooks) { runtime.registry.bluebooks.values }

  def pizza_input(name)
    { name: { value: name }, pizza: { price_cents: { cents: 900 }, size: { value: "small" } } }
  end

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
    it "treats a bare scalar and a wrapped value object as equal", :aggregate_failures do
      value_object = runtime.registry.bluebook("Pizzas").aggregate("Order").value_object("PizzaName")
      wrapped = Hecks::Runtime::Value.new(value_object, { value: "Margherita" })

      expect(described_class.normalize(wrapped)).to eq(described_class.normalize({ value: "Margherita" }))
      expect(described_class.normalize({ value: "Margherita" })).to eq(described_class.normalize("Margherita"))
    end
  end

  describe "one boot per suite" do
    let(:suite) { Hecks::Behaviors::BehaviorsSuite.new(loads: [File.join(root, "pizzas.bluebook"), memory_hecksagon]) }

    around { |example| Dir.mktmpdir { |dir| (@dir = dir) && example.run } }

    def create(name)
      Hecks::Behaviors::TestCase.new(description: name, tests_command: "CreatePizza", on_aggregate: "Order",
                                     kind: :command, setups: [], expect: { ok: true }, input: pizza_input(name))
    end

    # Runs two tests against the suite's one runtime, as the next test would after the first.
    #
    # @return [Hecks::Runtime] the suite's runtime once the second has run
    def run_two_tests
      described_class.run_one(create("First"), suite)
      described_class.run_one(create("Second"), suite)
      described_class.runtime_for(suite)
    end

    def copied_loads
      suite.loads.map do |path|
        FileUtils.cp(path, @dir)
        File.join(@dir, File.basename(path))
      end
    end

    it "reuses the suite's runtime across tests" do
      first = described_class.runtime_for(suite)
      expect(described_class.runtime_for(suite)).to be(first)
    end

    # The isolation a per-test boot would buy: nothing the first test
    # dispatched is visible to the second — not its events, not its
    # records.
    it "passes a test and records what it dispatched", :aggregate_failures do
      expect(described_class.run_one(create("First"), suite).status).to eq(:pass)
      expect(described_class.runtime_for(suite).registry.event_log).not_to be_empty
    end

    it "passes the second test run after the first" do
      described_class.run_one(create("First"), suite)

      expect(described_class.run_one(create("Second"), suite).status).to eq(:pass)
    end

    it "resets the events a test wrote before the next one runs" do
      events = run_two_tests.registry.event_log

      expect(events.map { |e| e.payload[:name] }.map { |n| Hecks::Runtime::Value.materialize(n) })
        .to eq([{ value: "Second" }])
    end

    it "resets the records a test wrote before the next one runs" do
      booted = run_two_tests
      order = booted.registry.bluebook("Pizzas").aggregate("Order")

      expect(booted.registry.repository("Pizzas", order).all.map(&:id)).to eq(["Second"])
    end

    it "boots fresh when a loaded file changes" do
      copy = Hecks::Behaviors::BehaviorsSuite.new(loads: copied_loads)
      before = described_class.runtime_for(copy)
      FileUtils.touch(copy.loads.first, mtime: Time.now + 5)

      expect(described_class.runtime_for(copy)).not_to be(before)
    end
  end

  describe "refused: matching" do
    let(:suite) { Hecks::Behaviors::BehaviorsSuite.new(loads: [File.join(root, "pizzas.bluebook"), memory_hecksagon]) }

    def test_case(tests_command:, on_aggregate:, input:, expect:, setups: [])
      Hecks::Behaviors::TestCase.new(description: "t", tests_command: tests_command, on_aggregate: on_aggregate,
                                     kind: :command, setups: setups, input: input, expect: expect)
    end

    # A test adding a zero-amount topping to a pizza created by its setup, expecting a refusal.
    def refused_topping_test(name, refused)
      setup = Hecks::Behaviors::TestSetup.new(command: "CreatePizza", args: pizza_input(name))
      test_case(tests_command: "AddTopping", on_aggregate: "Order", setups: [setup],
                input: { name: name, topping: { value: "Basil" }, amount: { value: 0 } },
                expect: { refused: refused })
    end

    it "passes ok: true for a command that succeeds" do
      test = test_case(tests_command: "CreatePizza", on_aggregate: "Order", input: pizza_input("Ok"),
                       expect: { ok: true })
      expect(described_class.run_one(test, suite).status).to eq(:pass)
    end

    it "passes when the refusal message includes the expected substring" do
      run = described_class.run_one(refused_topping_test("Sealed", "an amount is positive"), suite)
      expect(run.status).to eq(:pass)
    end

    it "fails when the refusal happened but the message doesn't match, showing both", :aggregate_failures do
      run = described_class.run_one(refused_topping_test("Sealed2", "a sold pizza cannot be changed"), suite)
      expect(run.status).to eq(:fail)
      expect(run.message).to include("an amount is positive")
    end

    it "fails when expect refused: is set but the dispatch actually succeeded", :aggregate_failures do
      test = test_case(tests_command: "CreatePizza", on_aggregate: "Order", input: pizza_input("Succeeds"),
                       expect: { refused: "anything" })
      run = described_class.run_one(test, suite)
      expect(run.status).to eq(:fail)
      expect(run.message).to include("dispatch succeeded")
    end
  end

  # Without a call to check_fields, a field expectation (or a typo'd key)
  # on a query would silently pass no matter what the query actually
  # answered.
  describe "field expectations on a query" do
    let(:suite) { Hecks::Behaviors::BehaviorsSuite.new(loads: [File.join(root, "pizzas.bluebook"), memory_hecksagon]) }

    def create_setup(name)
      Hecks::Behaviors::TestSetup.new(command: "CreatePizza",
                                      args:    { name:  { value: name },
                                                 pizza: { price_cents: { cents: 900 }, size: { value: "small" } } })
    end

    def query_test(setups:, expect:)
      Hecks::Behaviors::TestCase.new(description: "q", tests_command: "Available", on_aggregate: "Order",
                                     kind: :query, setups: setups, input: {}, expect: expect)
    end

    it "checks a field on the query's single row" do
      test = query_test(setups: [create_setup("Solo")], expect: { status: "available" })
      expect(described_class.run_one(test, suite).status).to eq(:pass)
    end

    it "fails when the field doesn't match", :aggregate_failures do
      test = query_test(setups: [create_setup("Solo2")], expect: { status: "sold" })
      run = described_class.run_one(test, suite)
      expect(run.status).to eq(:fail)
      expect(run.message).to include("status")
    end

    it "fails a typo'd key instead of silently ignoring it", :aggregate_failures do
      test = query_test(setups: [create_setup("Solo3")], expect: { staytus: "available" })
      run = described_class.run_one(test, suite)
      expect(run.status).to eq(:fail)
      expect(run.message).to include("staytus")
    end

    it "refuses to guess which row a field expectation describes when more than one comes back", :aggregate_failures do
      test = query_test(setups: [create_setup("A"), create_setup("B")], expect: { status: "available" })
      run = described_class.run_one(test, suite)
      expect(run.status).to eq(:fail)
      expect(run.message).to include("2 rows")
    end
  end
end
