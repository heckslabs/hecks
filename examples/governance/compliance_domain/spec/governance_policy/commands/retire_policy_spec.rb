require_relative "../../spec_helper"

RSpec.describe ComplianceDomain::GovernancePolicy::Commands::RetirePolicy do
  describe "attributes" do
    subject(:command) { described_class.new(policy_id: "example") }

    it "has policy_id" do
      expect(command.policy_id).to eq("example")
    end

  end

  describe "event" do
    it "emits RetiredPolicy" do
      expect(described_class.event_name).to eq("RetiredPolicy")
    end
  end

  describe "execution" do
    before { @app = Hecks.load(domain, force: true) }

    it "updates the aggregate and emits RetiredPolicy" do
      agg = GovernancePolicy.create(
          name: "example",
          description: "example",
          category: "example",
          framework_id: "ref-id-123"
        )
      GovernancePolicy.retire(policy_id: "example")
      event_names = @app.events.map { |e| e.class.name.split("::").last }
      expect(event_names).to include("RetiredPolicy")
    end
  end
end
