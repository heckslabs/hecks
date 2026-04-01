require_relative "../../spec_helper"

RSpec.describe ComplianceDomain::GovernancePolicy::Commands::ActivatePolicy do
  describe "attributes" do
    subject(:command) { described_class.new(policy_id: "example", effective_date: Date.today) }

    it "has policy_id" do
      expect(command.policy_id).to eq("example")
    end

    it "has effective_date" do
      expect(command.effective_date).to eq(Date.today)
    end

  end

  describe "event" do
    it "emits ActivatedPolicy" do
      expect(described_class.event_name).to eq("ActivatedPolicy")
    end
  end

  describe "execution" do
    before { @app = Hecks.load(domain, force: true) }

    it "updates the aggregate and emits ActivatedPolicy" do
      agg = GovernancePolicy.create(
          name: "example",
          description: "example",
          category: "example",
          framework_id: "ref-id-123"
        )
      GovernancePolicy.activate(policy_id: "example", effective_date: Date.today)
      event_names = @app.events.map { |e| e.class.name.split("::").last }
      expect(event_names).to include("ActivatedPolicy")
    end
  end
end
