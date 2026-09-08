require "tmpdir"
require "fileutils"
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

  describe "one boot per suite" do
    let(:suite) { Hecks::Behaviors::BehaviorsSuite.new(loads: [File.join(root, "pizzas.bluebook"), memory_hecksagon]) }

    def create(name)
      Hecks::Behaviors::TestCase.new(description: name, tests_command: "CreatePizza", on_aggregate: "Order",
                                     kind: :command, setups: [], expect: { ok: true },
                                     input: { name:  { value: name },
                                              pizza: { price_cents: { cents: 900 }, size: { value: "small" } } })
    end

    it "reuses the suite's runtime across tests" do
      first = described_class.runtime_for(suite)
      expect(described_class.runtime_for(suite)).to be(first)
    end

    # THE ISOLATION THE PER-TEST BOOT USED TO BUY: nothing the first test
    # dispatched is visible to the second — not its events, not its
    # records.
    it "resets everything a test wrote before the next one runs" do
      expect(described_class.run_one(create("First"), suite).status).to eq(:pass)
      runtime = described_class.runtime_for(suite)
      expect(runtime.registry.event_log).not_to be_empty

      expect(described_class.run_one(create("Second"), suite).status).to eq(:pass)
      expect(runtime.registry.event_log.map { |e| e.payload[:name] }.map { |n| Hecks::Runtime::Value.materialize(n) })
        .to eq([{ value: "Second" }])
      order = runtime.registry.bluebook("Pizzas").aggregate("Order")
      expect(runtime.registry.repository("Pizzas", order).all.map(&:id)).to eq(["Second"])
    end

    it "boots fresh when a loaded file changes" do
      Dir.mktmpdir do |dir|
        files = suite.loads.map do |path|
          FileUtils.cp(path, dir)
          File.join(dir, File.basename(path))
        end
        copy = Hecks::Behaviors::BehaviorsSuite.new(loads: files)
        before = described_class.runtime_for(copy)
        FileUtils.touch(files.first, mtime: Time.now + 5)
        expect(described_class.runtime_for(copy)).not_to be(before)
      end
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

  # run_query used to never call check_fields at all — a field
  # expectation (or a typo'd key) on a query silently passed no matter
  # what the query actually answered.
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

    it "fails when the field doesn't match" do
      test = query_test(setups: [create_setup("Solo2")], expect: { status: "sold" })
      run = described_class.run_one(test, suite)
      expect(run.status).to eq(:fail)
      expect(run.message).to include("status")
    end

    it "fails a typo'd key instead of silently ignoring it" do
      test = query_test(setups: [create_setup("Solo3")], expect: { staytus: "available" })
      run = described_class.run_one(test, suite)
      expect(run.status).to eq(:fail)
      expect(run.message).to include("staytus")
    end

    it "refuses to guess which row a field expectation describes when more than one comes back" do
      test = query_test(setups: [create_setup("A"), create_setup("B")], expect: { status: "available" })
      run = described_class.run_one(test, suite)
      expect(run.status).to eq(:fail)
      expect(run.message).to include("2 rows")
    end
  end
end
