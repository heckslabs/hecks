require_relative "../../spec_helper"

RSpec.describe ComplianceDomain::GovernancePolicy::Commands::CreatePolicy do
  describe "attributes" do
    subject(:command) { described_class.new(
          name: "example",
          description: "example",
          category: "example",
          framework_id: "ref-id-123"
        ) }

    it "has name" do
      expect(command.name).to eq("example")
    end

    it "has description" do
      expect(command.description).to eq("example")
    end

    it "has category" do
      expect(command.category).to eq("example")
    end

    it "has framework_id" do
      expect(command.framework_id).to eq("ref-id-123")
    end

  end

  describe "event" do
    it "emits CreatedPolicy" do
      expect(described_class.event_name).to eq("CreatedPolicy")
    end
  end

  describe "execution" do
    before { @app = Hecks.load(domain, force: true) }

    it "persists the aggregate" do
      result = GovernancePolicy.create(
          name: "example",
          description: "example",
          category: "example",
          framework_id: "ref-id-123"
        )
      expect(result).not_to be_nil
      expect(GovernancePolicy.find(result.id)).not_to be_nil
    end

    it "emits CreatedPolicy to the event log" do
      GovernancePolicy.create(
          name: "example",
          description: "example",
          category: "example",
          framework_id: "ref-id-123"
        )
      event_names = @app.events.map { |e| e.class.name.split("::").last }
      expect(event_names).to include("CreatedPolicy")
    end
  end
end
