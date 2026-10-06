require "spec_helper"

# Reading a declared-but-absent attribute (ADR 0025): optional yields nil, while a required one
# with no default raises, so a `given`/`ensures` never evaluates against a value nobody wrote.
RSpec.describe "reading a declared attribute a record predates" do
  ACCOUNT_BODY = proc do
    identified_by :number

    attribute :number,  Number
    attribute :balance, Balance
    attribute :note,    Note, optional: true

    value_object("Number")  { attribute :value, String }
    value_object("Balance") { attribute :cents, Integer }
    value_object("Note")    { attribute :value, String }
  end

  def aggregate_without_defaults
    registry = Hecks::Runtime::Registry.new
    Hecks.with_registry(registry) do
      Kernel.load(InMemoryDomain::EXTRACTION_PORT)
      Kernel.load(InMemoryDomain::PRISM_ADAPTER)
      Hecks.bluebook("Absence") { aggregate("Account", &ACCOUNT_BODY) }
    end
    registry.bluebook("Absence").aggregate("Account")
  end

  def debit(givens: [], ensures: [])
    FakeCommand.new(givens, ensures, [], "Debit")
  end

  def absent_balance_error
    "Account balance is absent on this record — declared, not optional, and added since it was " \
      "written. Backfill it in a translation (backfill :balance, default: ...), or declare it optional: true"
  end

  # `balance` is required with no default, but missing from the stored state, as in a record
  # written before the attribute existed.
  def record_predating_balance(aggregate)
    Hecks::Runtime::Instance.new(
      aggregate: aggregate, id: "a1", state: { number: { "value" => "a1" } }
    )
  end

  def rules = Hecks::Runtime::CommandRules.new(Hecks::Runtime::Registry.new)

  FakeCommand = Struct.new(:givens, :ensures, :attributes, :hecks_name)

  def given(canonical) = Hecks::Bluebook::Given.new(description: "balance check", canonical: canonical, predicate: nil)

  it "raises AttributeAbsent, naming the aggregate and field, when a given reads it" do
    record  = record_predating_balance(aggregate_without_defaults)
    command = debit(givens: [given("balance.cents > 0")])

    expect { rules.enforce_givens(record, command, {}, domain: "Absence") }
      .to raise_error(Hecks::Runtime::AttributeAbsent, absent_balance_error)
  end

  it "raises the same way when an ensures reads it, not just a given" do
    record  = record_predating_balance(aggregate_without_defaults)
    command = debit(ensures: [given("balance.cents > 0")])
    old     = { number: { "value" => "a1" } }

    expect { rules.enforce_ensures(record, command, {}, old: old, domain: "Absence") }
      .to raise_error(Hecks::Runtime::AttributeAbsent, /Account balance is absent/)
  end

  it "still reads nil for an OPTIONAL field a record predates — unchanged, not a regression" do
    instance = record_predating_balance(aggregate_without_defaults)
    command  = debit(givens: [given("note.value == nil")])

    expect { rules.enforce_givens(instance, command, {}, domain: "Absence") }.not_to raise_error
  end
end
