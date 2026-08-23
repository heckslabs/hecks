require "spec_helper"

RSpec.describe "relationship cardinality and traversal" do
  def boot_relationship_semantics
    registry = Hecksagain::Runtime::Registry.new

    Hecksagain.with_registry(registry) do
      Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
      Kernel.load(InMemoryDomain::EXTRACTION_PORT)
      Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
      Kernel.load(InMemoryDomain::PRISM_ADAPTER)

      Hecks.bluebook "RelationshipSemantics" do
        vision "relationship cardinality and paths retain their domain meaning"

        aggregate "Owner" do
          value_object("OwnerNumber") { attribute :value, String }
          identified_by OwnerNumber, as: :number

          command "Register" do
            goal "Register an owner"
            attribute :number, OwnerNumber
          end
        end

        aggregate "Customer" do
          value_object("CustomerNumber") { attribute :value, String }
          identified_by CustomerNumber, as: :number

          lifecycle :status, default: "active" do
            transition "Suspend" => "suspended", from: "active"
          end

          command "Register" do
            goal "Register a customer"
            attribute :number, CustomerNumber
          end

          command "Suspend" do
            goal "Suspend a customer"
            reference_to Customer
          end
        end

        aggregate "Team" do
          value_object("TeamNumber") { attribute :value, String }
          identified_by TeamNumber, as: :number

          belongs_to Owner
          has_one Owner, as: :sponsor, optional: true
          has_many Customers

          command "Form" do
            goal "Form a team"
            attribute :number, TeamNumber
            sets :owner
            sets :customers
          end

          command "FormWithoutOwner" do
            goal "Demonstrate the required relationship boundary"
            attribute :number, TeamNumber
            sets :customers
          end

          query "WithActiveCustomer" do
            where "customers/status": "active"
          end
        end
      end

      Hecks.hecksagon("RelationshipSemantics") do
        ::RelationshipSemantics::Owner.persisted_by("Memory")
        ::RelationshipSemantics::Customer.persisted_by("Memory")
        ::RelationshipSemantics::Team.persisted_by("Memory")
      end
    end

    registry.verify!
    Hecksagain::Runtime::Loader.bind_runtime(Hecksagain::Runtime::Dispatcher.new(registry))
  end

  let(:runtime) { boot_relationship_semantics }

  before do
    runtime.dispatch("RelationshipSemantics::Owner.Register", number: "owner-1")
    runtime.dispatch("RelationshipSemantics::Customer.Register", number: "customer-1")
    runtime.dispatch("RelationshipSemantics::Customer.Register", number: "customer-2")
    runtime.dispatch("RelationshipSemantics::Customer.Suspend", number: "customer-2")
  end

  it "treats a has_many query hop as an existential traversal" do
    runtime.dispatch(
      "RelationshipSemantics::Team.Form",
      number:    "team-mixed",
      owner:     "owner-1",
      customers: %w[customer-1 customer-2]
    )
    runtime.dispatch(
      "RelationshipSemantics::Team.Form",
      number:    "team-suspended",
      owner:     "owner-1",
      customers: %w[customer-2]
    )
    runtime.dispatch(
      "RelationshipSemantics::Team.Form",
      number:    "team-empty",
      owner:     "owner-1",
      customers: []
    )

    native = runtime.query("RelationshipSemantics::Team.WithActiveCustomer").map { |row| row[:id] }
    reference = runtime.reference_query("RelationshipSemantics::Team.WithActiveCustomer").map { |row| row[:id] }

    expect(native).to eq(%w[team-mixed])
    expect(reference).to eq(native)
  end

  it "requires one identity for a required to-one relationship" do
    expect do
      runtime.dispatch(
        "RelationshipSemantics::Team.FormWithoutOwner",
        number:    "team-orphaned",
        customers: []
      )
    end.to raise_error(
      Hecksagain::Runtime::TypeMismatch,
      /Team\.owner is a required belongs_to relationship.*one Owner identity.*nil/
    )
  end

  it "allows an absent optional to-one and an empty has_many" do
    team = runtime.dispatch(
      "RelationshipSemantics::Team.Form",
      number:    "team-empty",
      owner:     "owner-1",
      customers: []
    )

    expect(team.state[:sponsor]).to be_nil
    expect(team.state[:customers]).to eq([])
  end

  it "hydrates a has_many handle accessor without changing raw identity access" do
    runtime.dispatch(
      "RelationshipSemantics::Team.Form",
      number:    "team-handles",
      owner:     "owner-1",
      customers: %w[customer-1 customer-2]
    )

    team = RelationshipSemantics::Team.find("team-handles")

    expect(team[:customers]).to eq(%w[customer-1 customer-2])
    expect(team.customers.map(&:id)).to eq(%w[customer-1 customer-2])
    expect(team.owner.id).to eq("owner-1")
    expect(team.sponsor).to be_nil
  end
end
