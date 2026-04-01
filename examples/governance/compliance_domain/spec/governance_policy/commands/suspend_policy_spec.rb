require_relative "../../spec_helper"

RSpec.describe ComplianceDomain::GovernancePolicy::Commands::SuspendPolicy do
  describe "attributes" do
    subject(:command) { described_class.new(policy_id: "example") }

    it "has policy_id" do
      expect(command.policy_id).to eq("example")
    end

  end

  describe "event" do
    it "emits SuspendedPolicy" do
      expect(described_class.event_name).to eq("SuspendedPolicy")
    end
  end

  describe "execution" do
    before { @app = Hecks.load(domain, force: true) }

    it "updates the aggregate and emits SuspendedPolicy" do
      agg = GovernancePolicy.create(
          name: "example",
          description: "example",
          category: "example",
          framework_id: "ref-id-123"
        )
      GovernancePolicy.suspend(policy_id: "example")
      event_names = @app.events.map { |e| e.class.name.split("::").last }
      expect(event_names).to include("SuspendedPolicy")
    end
  end
end
