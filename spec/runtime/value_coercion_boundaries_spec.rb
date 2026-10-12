require "spec_helper"

# The edges of `Value::Coercion#for_attribute` that mutation testing found nothing pinning: the
# default boundary check, a value object offered into a differently named slot, and a nil
# argument for a list, a reference, or an attribute the aggregate does not declare.
RSpec.describe Hecks::Runtime::Value::Coercion do
  BOUNDARY_BLUEBOOK = <<~RUBY.freeze
    Hecks.bluebook "Boundary" do
      vision "A ledger with a count, a balance, a list and an owner."

      aggregate "Owner" do
        description "Who a ledger belongs to."
        value_object("OwnerName") { attribute :value, String }
        identified_by OwnerName, as: :name

        command "Join" do
          attribute :name, OwnerName
          emits Joined
        end
      end

      aggregate "Ledger" do
        description "A ledger."
        value_object("LedgerName") { attribute :value, String }
        value_object("Money") { attribute :cents, Integer }
        value_object("Credit") { attribute :cents, Integer }
        value_object("Note") { attribute :value, String }
        identified_by LedgerName, as: :name
        reference_to Owner
        attribute :balance, Money
        attribute :notes, list_of(Note)

        command "Open" do
          attribute :name, LedgerName
          emits Opened
        end
      end
    end
  RUBY

  let(:ledger) do
    registry = Hecks::Runtime::Registry.new
    Hecks.with_registry(registry) do
      Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
      Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
      eval(BOUNDARY_BLUEBOOK, TOPLEVEL_BINDING)
    end
    registry.bluebook("Boundary").aggregate("Ledger")
  end

  def coerce(attribute, value, **) = Hecks::Runtime::Value.for_attribute(ledger, attribute, value, **)

  def attribute(name) = ledger.attribute(name)

  # A query argument typed with a bare primitive, which no aggregate attribute may be.
  def count = Hecks::Bluebook::Attribute.new(name: :count, type: "Integer")

  def money(cents) = Hecks::Runtime::Value.build(ledger.value_object("Money"), cents: cents)

  def credit(cents) = Hecks::Runtime::Value.build(ledger.value_object("Credit"), cents: cents)

  it "refuses a wrong-typed bare primitive at the boundary by default" do
    expect { coerce(count, "many") }.to raise_error(Hecks::Runtime::TypeMismatch)
  end

  it "leaves a bare primitive alone when boundary is false, as a query argument is" do
    expect(coerce(count, "many", boundary: false)).to eq("many")
  end

  it "hands back the very value object it was offered when it is already the declared type" do
    held = money(5)

    expect(coerce(attribute(:balance), held)).to be(held)
  end

  it "rebuilds a same-shaped value object of another name as the declared type", :aggregate_failures do
    result = coerce(attribute(:balance), credit(5))

    expect(result.type_name).to eq("Money")
    expect(result.cents).to eq(5)
  end

  it "answers nil for an attribute the aggregate does not declare, even for a nil argument" do
    expect(coerce(nil, nil, argument: true)).to be_nil
  end

  it "passes a nil argument through for a list" do
    expect(coerce(attribute(:notes), nil, argument: true)).to be_nil
  end

  it "passes a nil argument through for a reference" do
    expect(coerce(attribute(:owner), nil, argument: true)).to be_nil
  end
end
