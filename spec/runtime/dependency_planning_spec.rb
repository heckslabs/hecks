require "spec_helper"

RSpec.describe Hecks::Runtime::DependencyPlanning do
  def field(name, type)
    Hecks::Bluebook::Attribute.new(name: name, type: type)
  end

  def mutation(target, op, source)
    Hecks::Bluebook::Mutation.new(target: target, op: op, source: source)
  end

  let(:sku) { field(:sku, String) }
  let(:label) { field(:label, String) }
  let(:quantity) { field(:quantity, Integer) }
  let(:amount) { field(:amount, Integer) }

  let(:register) do
    Hecks::Bluebook::Command.declare(
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
    Hecks::Bluebook::Command.declare(
      name:       "Restock",
      attributes: [amount],
      givens:     [
        Hecks::Bluebook::Given.new(
          description: "the amount is positive",
          canonical:   "amount > 0"
        )
      ],
      ensures:    [
        Hecks::Bluebook::Given.new(
          description: "the stock grew by the amount",
          canonical:   "quantity == old.quantity + amount"
        )
      ],
      mutations:  [mutation(:quantity, :increment, :amount)]
    )
  end

  let(:inventory_item) do
    Hecks::Bluebook::Aggregate.new(
      name:          "InventoryItem",
      attributes:    [sku, label, quantity],
      commands:      [register, restock],
      identified_by: [:sku],
      invariants:    [
        Hecks::Bluebook::Invariant.new(
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
    notes = Hecks::Bluebook::Attribute.new(name: :notes, type: String, list: true)
    nickname = Hecks::Bluebook::Attribute.new(name: :nickname, type: String, optional: true)
    enabled = Hecks::Bluebook::Attribute.new(name: :enabled, type: TrueClass, default: true)
    aggregate = Hecks::Bluebook::Aggregate.new(
      name:          "DefaultedItem",
      attributes:    [sku, notes, nickname, enabled],
      commands:      [],
      identified_by: [:sku]
    )
    command = Hecks::Bluebook::Command.declare(
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

  # `root_aggregate:` — Wave 8's own corpus audit surfaced this as a real
  # bug, not a hypothetical one: `EntityInterpreter` calls the Analyzer
  # with `aggregate:` set to the ENTITY (`owner_fields` is the entity's
  # own attribute set), but a `given`/`ensures` reading `parent.X` always
  # means the ROOT aggregate's own field — genuinely different owners.
  # Real, live corpus example this ports directly:
  # `Banking::Account.LedgerEntry.Amend`'s own `given("customer is
  # active") { parent.customer.status == "active" }`.
  describe "an entity-owned command's own parent.* reads" do
    let(:status) { field(:status, String) }
    let(:narrative) { field(:narrative, String) }

    let(:root_aggregate) do
      Hecks::Bluebook::Aggregate.new(name: "Account", attributes: [status, field(:number, String)], commands: [], identified_by: [:number])
    end

    let(:amend) do
      Hecks::Bluebook::Command.declare(
        name:       "Amend",
        attributes: [narrative],
        givens:     [Hecks::Bluebook::Given.new(description: "account is open", canonical: 'parent.status == "open"')],
        mutations:  [mutation(:narrative, :set, :narrative)]
      )
    end

    let(:ledger_entry) do
      Hecks::Bluebook::Entity.declare(name: "LedgerEntry", attributes: [narrative], commands: [amend])
    end

    it "resolves against the ENTITY's own fields when no root_aggregate is given — the pre-fix, still-real default for a plain aggregate command" do
      plan = described_class::Analyzer.call(aggregate: ledger_entry, command: amend)

      expect(plan.unresolved_dependencies).to eq(["parent.status does not name parent aggregate state"])
    end

    it "resolves parent.* against the ROOT aggregate's own fields when root_aggregate: is given, matching EntityInterpreter's real call site" do
      plan = described_class::Analyzer.call(aggregate: ledger_entry, command: amend, root_aggregate: root_aggregate)

      expect(plan.unresolved_dependencies).to eq([])
      expect(plan.read_set).to include(:status)
    end
  end
end
