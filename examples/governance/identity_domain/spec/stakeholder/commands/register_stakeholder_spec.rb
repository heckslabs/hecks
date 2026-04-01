require_relative "../../spec_helper"

RSpec.describe IdentityDomain::Stakeholder::Commands::RegisterStakeholder do
  describe "attributes" do
    subject(:command) { described_class.new(
          name: "example",
          email: "example",
          role: "example",
          team: "example"
        ) }

    it "has name" do
      expect(command.name).to eq("example")
    end

    it "has email" do
      expect(command.email).to eq("example")
    end

    it "has role" do
      expect(command.role).to eq("example")
    end

    it "has team" do
      expect(command.team).to eq("example")
    end

  end

  describe "event" do
    it "emits RegisteredStakeholder" do
      expect(described_class.event_name).to eq("RegisteredStakeholder")
    end
  end

  describe "execution" do
    before { @app = Hecks.load(domain, force: true) }

    it "persists the aggregate" do
      result = Stakeholder.register(
          name: "example",
          email: "example",
          role: "example",
          team: "example"
        )
      expect(result).not_to be_nil
      expect(Stakeholder.find(result.id)).not_to be_nil
    end

    it "emits RegisteredStakeholder to the event log" do
      Stakeholder.register(
          name: "example",
          email: "example",
          role: "example",
          team: "example"
        )
      event_names = @app.events.map { |e| e.class.name.split("::").last }
      expect(event_names).to include("RegisteredStakeholder")
    end
  end
end
