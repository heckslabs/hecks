require "spec_helper"

RSpec.describe Hecksagain::Runtime::DependencyPlanning do
  def field(name, type)
    Hecksagain::Bluebook::Attribute.new(name: name, type: type)
  end

  def mutation(target, op, source)
    Hecksagain::Bluebook::Mutation.new(target: target, op: op, source: source)
  end

  let(:sku) { field(:sku, String) }
  let(:label) { field(:label, String) }
  let(:quantity) { field(:quantity, Integer) }
  let(:amount) { field(:amount, Integer) }

  let(:register) do
    Hecksagain::Bluebook::Command.declare(
      name:       "Register",
      attributes: [sku, label, quantity],
      mutations:  [
        mutation(:sku, :set, :sku),
        mutation(:label, :set, :label),
        mutation(:quantity, :set, :quantity)
      ]
    )
  end

  let(:restock) do
    Hecksagain::Bluebook::Command.declare(
      name:       "Restock",
      attributes: [amount],
      givens:     [
        Hecksagain::Bluebook::Given.new(
          description: "the amount is positive",
          canonical:   "amount > 0"
        )
      ],
      ensures:    [
        Hecksagain::Bluebook::Given.new(
          description: "the stock grew by the amount",
          canonical:   "quantity == old.quantity + amount"
        )
      ],
      mutations:  [mutation(:quantity, :increment, :amount)]
    )
  end

  let(:inventory_item) do
    Hecksagain::Bluebook::Aggregate.new(
      name:          "InventoryItem",
      attributes:    [sku, label, quantity],
      commands:      [register, restock],
      identified_by: [:sku],
      invariants:    [
        Hecksagain::Bluebook::Invariant.new(
          description: "stock is never negative",
          canonical:   "quantity >= 0"
        )
      ]
    )
  end

  def plan(command)
    described_class::Analyzer.call(aggregate: inventory_item, command: command)
  end

  it "proves a complete replacement from canonical expressions and mutations" do
    register_plan = plan(register)

    expect(register_plan.read_set).to eq([])
    expect(register_plan.payload_read_set).to eq(%i[label quantity sku])
    expect(register_plan.write_set).to eq(%i[label quantity sku])
    expect(register_plan).to be_complete_state
    expect(register_plan).to be_state_independent
    expect(register_plan.unresolved_dependencies).to eq([])
  end

  it "keeps a partial state-dependent mutation on the correctness path" do
    restock_plan = plan(restock)

    expect(restock_plan.read_set).to eq(%i[label quantity sku])
    expect(restock_plan.payload_read_set).to eq([:amount])
    expect(restock_plan.write_set).to eq([:quantity])
    expect(restock_plan).not_to be_complete_state
    expect(restock_plan).not_to be_state_independent
    expect(restock_plan.strategy_for(capabilities: [:atomic_put]))
      .to eq(:load_apply_validate_store)
  end

  it "requires both a semantic proof and adapter capability before recommending atomic put" do
    register_plan = plan(register)

    expect(register_plan.strategy_for).to eq(:load_apply_validate_store)
    expect(register_plan.strategy_for(capabilities: [:atomic_put])).to eq(:atomic_put)
  end

  it "counts deterministic fresh-instance defaults without calling them command mutations" do
    notes = Hecksagain::Bluebook::Attribute.new(name: :notes, type: String, list: true)
    nickname = Hecksagain::Bluebook::Attribute.new(name: :nickname, type: String, optional: true)
    enabled = Hecksagain::Bluebook::Attribute.new(name: :enabled, type: TrueClass, default: true)
    aggregate = Hecksagain::Bluebook::Aggregate.new(
      name:          "DefaultedItem",
      attributes:    [sku, notes, nickname, enabled],
      commands:      [],
      identified_by: [:sku]
    )
    command = Hecksagain::Bluebook::Command.declare(
      name:       "Register",
      attributes: [sku],
      mutations:  [mutation(:sku, :set, :sku)]
    )

    defaulted_plan = described_class::Analyzer.call(aggregate: aggregate, command: command)

    expect(defaulted_plan.read_set).to eq([])
    expect(defaulted_plan.write_set).to eq([:sku])
    expect(defaulted_plan).to be_complete_state
    expect(defaulted_plan).to be_state_independent
  end
end
