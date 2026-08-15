require "spec_helper"

# ADR 0025, "Added attributes and absence": the read-side half of S11.
# GuardState's own nil-read (hydrate_defaults_spec.rb's boot-time half —
# `Instance.hydrate_with_defaults` — is the write-side companion) used to
# answer nil for ANY declared-but-absent field, optional or not. That is
# exactly right for optional — nil is what optional means — and exactly
# wrong for a required field with no default: a `given`/`ensures` reading
# it would silently evaluate against a value nobody ever wrote, the same
# bug class as an unpopulated projection reading "not active". This pins
# the narrowed behaviour: optional stays nil, required raises named.
RSpec.describe "reading a declared attribute a record predates" do
  def aggregate_without_defaults
    registry = Hecksagain::Runtime::Registry.new
    Hecks.with_registry(registry) do
      Kernel.load(InMemoryDomain::EXTRACTION_PORT)
      Kernel.load(InMemoryDomain::PRISM_ADAPTER)
      Hecks.bluebook("Absence") do
        aggregate("Account") do
          identified_by :number

          attribute :number,  Number
          attribute :balance, Balance
          attribute :note,    Note, optional: true

          value_object("Number")  { attribute :value, String }
          value_object("Balance") { attribute :cents, Integer }
          value_object("Note")    { attribute :value, String }
        end
      end
    end
    registry.bluebook("Absence").aggregate("Account")
  end

  # `balance` is REQUIRED, no default: — declared, but stripped from the
  # stored state below, exactly as a record written before it existed
  # would arrive off any adapter's own decode.
  def record_predating_balance(aggregate)
    Hecksagain::Runtime::Instance.new(
      aggregate: aggregate, id: "a1", state: { number: { "value" => "a1" } }
    )
  end

  def rules = Hecksagain::Runtime::CommandRules.new(Hecksagain::Runtime::Registry.new)

  FakeCommand = Struct.new(:givens, :ensures, :attributes, :hecks_name)

  def given(canonical) = Hecksagain::Bluebook::Given.new(description: "balance check", canonical: canonical, predicate: nil)

  it "raises AttributeAbsent, naming the aggregate and field, when a given reads it" do
    aggregate = aggregate_without_defaults
    command   = FakeCommand.new([given("balance.cents > 0")], [], [], "Debit")

    expect { rules.enforce_givens(record_predating_balance(aggregate), command, {}, domain: "Absence") }
      .to raise_error(
        Hecksagain::Runtime::AttributeAbsent,
        "Account balance is absent on this record — declared, not optional, and added since it was " \
        "written. Backfill it in a translation (backfill :balance, default: ...), or declare it optional: true"
      )
  end

  it "raises the same way when an ensures reads it, not just a given" do
    aggregate = aggregate_without_defaults
    command   = FakeCommand.new([], [given("balance.cents > 0")], [], "Debit")
    old       = { number: { "value" => "a1" } }

    expect do
      rules.enforce_ensures(record_predating_balance(aggregate), command, {}, old: old, domain: "Absence")
    end.to raise_error(Hecksagain::Runtime::AttributeAbsent, /Account balance is absent/)
  end

  it "still reads nil for an OPTIONAL field a record predates — unchanged, not a regression" do
    aggregate = aggregate_without_defaults
    instance  = record_predating_balance(aggregate)
    command   = FakeCommand.new([given("note.value == nil")], [], [], "Debit")

    expect { rules.enforce_givens(instance, command, {}, domain: "Absence") }.not_to raise_error
  end
end
