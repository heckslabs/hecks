require "spec_helper"
require "hecksagain/presentation/field_shape"

RSpec.describe Hecksagain::Presentation::FieldShape do
  BANKING_BLUEBOOK = File.join(InMemoryDomain::ROOT, "examples/banking/bluebook/banking.bluebook")

  # No persistence adapter, no hecksagon, no verify! — a Field is derived
  # purely from the IR. The extraction port/adapter still has to be there
  # (`identified_by { ... }` recovers its own canonical text through it at
  # declare time), the one piece of wiring a bare `Kernel.load` can't skip.
  #
  # Booted ONCE per file, not per example — nothing below ever dispatches,
  # only reads the loaded IR back out, so a shared load is safe.
  before(:context) do
    registry = Hecksagain::Runtime::Registry.new
    Hecksagain.with_registry(registry) do
      Kernel.load(InMemoryDomain::EXTRACTION_PORT)
      Kernel.load(InMemoryDomain::PRISM_ADAPTER)
      Kernel.load(BANKING_BLUEBOOK)
    end
    @banking = registry.bluebook("Banking")
  end

  let(:account)  { @banking.aggregate("Account") }
  let(:customer) { @banking.aggregate("Customer") }

  def resolve(aggregate, attribute_name)
    described_class.resolve(aggregate.attribute(attribute_name), aggregate: aggregate)
  end

  it "unwraps a single-attribute value object to the inner scalar's own path" do
    field = resolve(customer, :reference) # CustomerNumber { value }
    expect(field.path).to eq("reference.value")
    expect(field.kind).to eq(:text)
  end

  it "reads a pattern naming '@' as an email input, even nested inside a value object" do
    field = resolve(customer, :email) # EmailAddress { address, pattern: .../@/... }
    expect(field.path).to eq("email.address")
    expect(field.html_type).to eq("email")
  end

  it "renders a same-attribute one_of value object as a closed set at its own discriminant path" do
    field = resolve(account, :kind) # AccountKind { name }, one_of current/savings/reserve
    expect(field.path).to eq("kind.name")
    expect(field.kind).to eq(:radio) # <= 4 members
    expect(field.options.map(&:first)).to contain_exactly("current", "savings", "reserve")
  end

  it "renders a cents+currency value object as :money with cents/currency children" do
    field = resolve(account, :balance) # Money { cents, currency }
    expect(field.kind).to eq(:money)
    expect(field.children.map(&:path)).to eq(%w[balance.cents balance.currency])
  end

  it "renders a reference-typed command argument as :reference, carrying the resolved target aggregate" do
    # Account's own cross-reference is declared via `reference_to Customer`
    # at the aggregate level, not as a plain `attribute` — a command that
    # addresses a new Account by its customer carries the reference as an
    # ordinary argument instead (Open's customer_id), which is what this checks.
    open = account.command("Open")
    field = described_class.resolve(open.attribute(:customer_id), aggregate: account)
    expect(field.kind).to eq(:reference)
    expect(field.target_aggregate.hecks_name).to eq("Customer")
  end

  it "renders a list_of attribute as :list, with the element's own shape as its one child" do
    field = resolve(account, :ledger)
    expect(field.kind).to eq(:list)
    expect(field.children.size).to eq(1)
  end

  it "leaves a plain admits: scalar's own set resolvable across aggregates" do
    entry = account.entities.find { |e| e.hecks_name == "LedgerEntry" }
    field = described_class.resolve(entry.attribute(:direction), aggregate: account)
    expect(field.path).to eq("direction.value") # MovementDirection { value }, admits Account::LedgerDirection
    expect(field.options.map(&:first)).to contain_exactly("credit", "debit")
  end

  it "humanizes a dotted path by its last segment, and an underscored name by all its words" do
    expect(Hecksagain::Presentation::Humanize.label("daily_limit")).to eq("Daily limit")
    expect(Hecksagain::Presentation::Humanize.label("amount.cents")).to eq("Cents")
  end
end
