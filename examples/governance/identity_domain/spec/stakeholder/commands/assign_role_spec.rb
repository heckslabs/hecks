require_relative "../../spec_helper"

RSpec.describe IdentityDomain::Stakeholder::Commands::AssignRole do
  describe "attributes" do
    subject(:command) { described_class.new(stakeholder_id: "example", role: "example") }

    it "has stakeholder_id" do
      expect(command.stakeholder_id).to eq("example")
    end

    it "has role" do
      expect(command.role).to eq("example")
    end

  end

  describe "event" do
    it "emits AssignedRole" do
      expect(described_class.event_name).to eq("AssignedRole")
    end
  end

  describe "execution" do
    before { @app = Hecks.load(domain, force: true) }

    it "updates the aggregate and emits AssignedRole" do
      agg = Stakeholder.register(
          name: "example",
          email: "example",
          role: "example",
          team: "example"
        )
      Stakeholder.assign_role(stakeholder_id: "example", role: "example")
      event_names = @app.events.map { |e| e.class.name.split("::").last }
      expect(event_names).to include("AssignedRole")
    end
  end
end
