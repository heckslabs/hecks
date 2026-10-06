require "spec_helper"
require_relative "../support/memory_ports"

RSpec.describe "relationship cardinality and traversal" do
  RELATIONSHIP_SEMANTICS_DOMAIN = proc do
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

  def bind_memory
    Hecks.hecksagon("RelationshipSemantics") do
      RelationshipSemantics::Owner.persisted_by("Memory")
      RelationshipSemantics::Customer.persisted_by("Memory")
      RelationshipSemantics::Team.persisted_by("Memory")
    end
  end

  def boot_relationship_semantics
    registry = Hecks::Runtime::Registry.new

    Hecks.with_registry(registry) do
      MemoryPorts.load!
      Hecks.bluebook("RelationshipSemantics", &RELATIONSHIP_SEMANTICS_DOMAIN)
      bind_memory
    end

    registry.verify!
    Hecks::Runtime::Loader.bind_runtime(Hecks::Runtime::Dispatcher.new(registry))
  end

  let(:runtime) { boot_relationship_semantics }

  before do
    runtime.dispatch_flat("RelationshipSemantics::Owner.Register", number: "owner-1")
    runtime.dispatch_flat("RelationshipSemantics::Customer.Register", number: "customer-1")
    runtime.dispatch_flat("RelationshipSemantics::Customer.Register", number: "customer-2")
    runtime.dispatch_flat("RelationshipSemantics::Customer.Suspend", number: "customer-2")
  end

  def form_team(number, customers)
    runtime.dispatch_flat("RelationshipSemantics::Team.Form", number: number, owner: "owner-1", customers: customers)
  end

  def team_ids(method)
    runtime.public_send(method, "RelationshipSemantics::Team.WithActiveCustomer").map { |row| row[:id] }
  end

  it "treats a has_many query hop as an existential traversal", :aggregate_failures do
    form_team("team-mixed", %w[customer-1 customer-2])
    form_team("team-suspended", %w[customer-2])
    form_team("team-empty", [])

    expect(team_ids(:query)).to eq(%w[team-mixed])
    expect(team_ids(:reference_query)).to eq(team_ids(:query))
  end

  it "requires one identity for a required to-one relationship" do
    expect { runtime.dispatch_flat("RelationshipSemantics::Team.FormWithoutOwner", number: "team-orphaned", customers: []) }
      .to raise_error(Hecks::Runtime::TypeMismatch,
                      /Team\.owner is a required belongs_to relationship.*one Owner identity.*nil/)
  end

  it "allows an absent optional to-one and an empty has_many", :aggregate_failures do
    team = form_team("team-empty", [])

    expect(team.state[:sponsor]).to be_nil
    expect(team.state[:customers]).to eq([])
  end

  it "hydrates a has_many handle accessor without changing raw identity access", :aggregate_failures do
    form_team("team-handles", %w[customer-1 customer-2])
    team = RelationshipSemantics::Team.find("team-handles")

    expect(team[:customers]).to eq(%w[customer-1 customer-2])
    expect(team.customers.map(&:id)).to eq(%w[customer-1 customer-2])
    expect([team.owner.id, team.sponsor]).to eq(["owner-1", nil])
  end
end
