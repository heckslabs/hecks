require "spec_helper"

RSpec.describe Hecks::Runtime::DependencyPlanning do
  def field(name, type)
    Hecks::Bluebook::Attribute.new(name: name, type: type)
  end

  def mutation(target, oper, source)
    Hecks::Bluebook::Mutation.new(target: target, op: oper, source: source)
  end

  def sku = @sku ||= field(:sku, String)
  def label = @label ||= field(:label, String)
  def quantity = @quantity ||= field(:quantity, Integer)
  def amount = @amount ||= field(:amount, Integer)

  def register
    @register ||= Hecks::Bluebook::Command.declare(
      name:       "Register",
      attributes: [sku, label, quantity],
      mutations:  [
        mutation(:sku, :set, :sku),
        mutation(:label, :set, :label),
        mutation(:quantity, :set, :quantity)
      ]
    )
  end

  def rule(description, canonical) = Hecks::Bluebook::Given.new(description: description, canonical: canonical)

  def restock
    @restock ||= Hecks::Bluebook::Command.declare(
      name:       "Restock",
      attributes: [amount],
      givens:     [rule("the amount is positive", "amount > 0")],
      ensures:    [rule("the stock grew by the amount", "quantity == old.quantity + amount")],
      mutations:  [mutation(:quantity, :increment, :amount)]
    )
  end

  def never_negative
    Hecks::Bluebook::Invariant.new(description: "stock is never negative", canonical: "quantity >= 0")
  end

  def inventory_item
    @inventory_item ||= Hecks::Bluebook::Aggregate.new(
      name:          "InventoryItem",
      attributes:    [sku, label, quantity],
      commands:      [register, restock],
      identified_by: [:sku],
      invariants:    [never_negative]
    )
  end

  def plan(command)
    described_class::Analyzer.call(aggregate: inventory_item, command: command)
  end

  it "proves a complete replacement's reads and writes from canonical expressions and mutations", :aggregate_failures do
    register_plan = plan(register)

    expect(register_plan.read_set).to eq([])
    expect(register_plan.payload_read_set).to eq(%i[label quantity sku])
    expect(register_plan.write_set).to eq(%i[label quantity sku])
  end

  it "proves a complete replacement is complete, state independent and fully resolved", :aggregate_failures do
    register_plan = plan(register)

    expect(register_plan).to be_complete_state
    expect(register_plan).to be_state_independent
    expect(register_plan.unresolved_dependencies).to eq([])
  end

  it "reads the stored state a partial mutation depends on", :aggregate_failures do
    restock_plan = plan(restock)

    expect(restock_plan.read_set).to eq(%i[label quantity sku])
    expect(restock_plan.payload_read_set).to eq([:amount])
    expect(restock_plan.write_set).to eq([:quantity])
  end

  it "keeps a partial state-dependent mutation on the correctness path", :aggregate_failures do
    restock_plan = plan(restock)

    expect(restock_plan).not_to be_complete_state
    expect(restock_plan).not_to be_state_independent
    expect(restock_plan.strategy_for(capabilities: [:atomic_put]))
      .to eq(:load_apply_validate_store)
  end

  it "requires both a semantic proof and adapter capability before recommending atomic put", :aggregate_failures do
    register_plan = plan(register)

    expect(register_plan.strategy_for).to eq(:load_apply_validate_store)
    expect(register_plan.strategy_for(capabilities: [:atomic_put])).to eq(:atomic_put)
  end

  describe "fresh-instance defaults" do
    def defaulted_aggregate
      notes = Hecks::Bluebook::Attribute.new(name: :notes, type: String, list: true)
      nickname = Hecks::Bluebook::Attribute.new(name: :nickname, type: String, optional: true)
      enabled = Hecks::Bluebook::Attribute.new(name: :enabled, type: TrueClass, default: true)
      Hecks::Bluebook::Aggregate.new(
        name:          "DefaultedItem",
        attributes:    [sku, notes, nickname, enabled],
        commands:      [],
        identified_by: [:sku]
      )
    end

    def defaulted_plan
      command = Hecks::Bluebook::Command.declare(
        name:       "Register",
        attributes: [sku],
        mutations:  [mutation(:sku, :set, :sku)]
      )
      described_class::Analyzer.call(aggregate: defaulted_aggregate, command: command)
    end

    it "counts deterministic fresh-instance defaults without calling them command mutations", :aggregate_failures do
      expect(defaulted_plan.read_set).to eq([])
      expect(defaulted_plan.write_set).to eq([:sku])
      expect(defaulted_plan).to be_complete_state
      expect(defaulted_plan).to be_state_independent
    end
  end

  # EntityInterpreter passes the entity as `aggregate:`, but `parent.X` in a given or
  # ensures names the root aggregate's field, hence `root_aggregate:`.
  describe "an entity-owned command's own parent.* reads" do
    def status = @status ||= field(:status, String)
    def narrative = @narrative ||= field(:narrative, String)

    def root_aggregate
      @root_aggregate ||= Hecks::Bluebook::Aggregate.new(
        name: "Account", attributes: [status, field(:number, String)], commands: [], identified_by: [:number]
      )
    end

    def amend
      @amend ||= Hecks::Bluebook::Command.declare(
        name:       "Amend",
        attributes: [narrative],
        givens:     [Hecks::Bluebook::Given.new(description: "account is open", canonical: 'parent.status == "open"')],
        mutations:  [mutation(:narrative, :set, :narrative)]
      )
    end

    def ledger_entry
      @ledger_entry ||= Hecks::Bluebook::Entity.declare(name: "LedgerEntry", attributes: [narrative], commands: [amend])
    end

    it "resolves against the ENTITY's own fields when no root_aggregate is given — the pre-fix, still-real " \
       "default for a plain aggregate command" do
      plan = described_class::Analyzer.call(aggregate: ledger_entry, command: amend)

      expect(plan.unresolved_dependencies).to eq(["parent.status does not name parent aggregate state"])
    end

    it "resolves parent.* against the ROOT aggregate's own fields when root_aggregate: is given, matching " \
       "EntityInterpreter's real call site", :aggregate_failures do
      plan = described_class::Analyzer.call(aggregate: ledger_entry, command: amend, root_aggregate: root_aggregate)

      expect(plan.unresolved_dependencies).to eq([])
      expect(plan.read_set).to include(:status)
    end
  end

  describe Hecks::Runtime::DependencyPlanning::ExpressionReads do
    let(:evaluator) { Hecks::Bluebook::Expression::Evaluator }

    def concurrent_answers
      threads = Array.new(8) do |n|
        Thread.new { Array.new(50) { described_class.paths("thread_probe_#{n % 3} > 0") } }
      end
      threads.flat_map(&:value)
    end

    it "answers the paths a rule reads, the same on every ask", :aggregate_failures do
      first = described_class.paths("amount > 0 && parent.limit > amount")

      expect(first).to eq(%w[amount parent.limit amount])
      expect(described_class.paths("amount > 0 && parent.limit > amount")).to eq(first)
    end

    it "parses a rule's text once, however many times a command is analyzed" do
      text = "quantity_unique_to_this_example > 0"
      allow(evaluator).to receive(:parse).and_call_original

      3.times { described_class.paths(text) }

      expect(evaluator).to have_received(:parse).with(text).once
    end

    it "hands out a frozen answer, so one caller cannot change what the next reads" do
      expect(described_class.paths("frozen_probe > 0")).to be_frozen
    end

    it "never remembers a text that fails to parse", :aggregate_failures do
      allow(evaluator).to receive(:parse).with("broken_probe ???").and_raise(ArgumentError, "unparseable")

      2.times { expect { described_class.paths("broken_probe ???") }.to raise_error(ArgumentError) }

      expect(evaluator).to have_received(:parse).with("broken_probe ???").twice
    end

    it "stays bounded however many distinct texts are asked", :aggregate_failures do
      stub_const("#{described_class}::PATHS_CACHE_LIMIT", 3)
      cache = described_class.const_get(:PATHS_CACHE)

      10.times { |n| described_class.paths("bound_probe_#{n} > 0") }

      expect(cache.size).to be <= 3
      expect(described_class.paths("bound_probe_9 > 0")).to eq(%w[bound_probe_9])
    end

    it "answers the same frozen paths to concurrent dispatch threads", :aggregate_failures do
      answers = concurrent_answers

      expect(answers).to all(be_frozen)
      expect(answers.uniq.size).to eq(3)
    end

    it "guards the cache with a lock" do
      expect(described_class.const_get(:PATHS_LOCK)).to be_a(Mutex)
    end
  end
end
