require "spec_helper"
require_relative "../support/booted_source"

# A validation checks the role first and alone: a caller who may not run a command learns only that,
# not which arguments or rules the command has.
RSpec.describe Hecks::Runtime::Dispatcher, "#validate and the caller's role" do
  KITCHEN_SOURCE = <<~BLUEBOOK.freeze
    Hecks.bluebook "Kitchen" do
      aggregate "Order" do
        identified_by :ref
        attribute :ref, Ref
        attribute :count, Count
        value_object("Ref") { attribute :value, String }
        value_object("Count") { attribute :value, Integer }
        command("Place") do
          role "Waiter"
          attribute :ref, Ref
          attribute :count, Count
          given("something is ordered") { count.value > 0 }
          sets :ref
          sets :count
          emits "OrderPlaced"
        end
      end
    end
  BLUEBOOK

  let(:dispatcher) do
    BootedSource.boot(KITCHEN_SOURCE, authorization: true) do
      Hecks.hecksagon("Kitchen") do
        attaches "Governance"
        Kitchen::Order.persisted_by("Memory")
      end
      Hecks.hecksagon("Governance") do
        Governance::RoleAssignment.persisted_by("Memory")
        Governance::RoleTransition.persisted_by("Memory")
      end
    end
  end

  def validate_place(role, **args)
    booted = dispatcher
    Hecks.as_caller(role: role) { booted.validate("Kitchen::Order.Place", **args) }
  end

  it "tells a caller without the role only that, though the arguments are wrong too", :aggregate_failures do
    result = validate_place("Chef", ref: { value: "o1" }, count: { value: 0 }, bogus: 1)

    expect(result.refusals.map(&:stage)).to eq([:role])
    expect(result.refusals.map(&:kind)).to eq([:unauthorized])
  end

  it "reports the rules to a caller who holds the role", :aggregate_failures do
    result = validate_place("Waiter", ref: { value: "o1" }, count: { value: 0 })

    expect(result.refusals.map(&:rule)).to eq(["something is ordered"])
    expect(result.refusals.map(&:stage)).to eq([:givens])
  end
end
