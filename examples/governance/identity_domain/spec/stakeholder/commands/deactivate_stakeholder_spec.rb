require_relative "../../spec_helper"

RSpec.describe IdentityDomain::Stakeholder::Commands::DeactivateStakeholder do
  describe "attributes" do
    subject(:command) { described_class.new(stakeholder_id: "example") }

    it "has stakeholder_id" do
      expect(command.stakeholder_id).to eq("example")
    end

  end

  describe "event" do
    it "emits DeactivatedStakeholder" do
      expect(described_class.event_name).to eq("DeactivatedStakeholder")
    end
  end

  describe "execution" do
    before { @app = Hecks.load(domain, force: true) }

    it "updates the aggregate and emits DeactivatedStakeholder" do
      agg = Stakeholder.register(
          name: "example",
          email: "example",
          role: "example",
          team: "example"
        )
      Stakeholder.deactivate(stakeholder_id: "example")
      event_names = @app.events.map { |e| e.class.name.split("::").last }
      expect(event_names).to include("DeactivatedStakeholder")
    end
  end
end
