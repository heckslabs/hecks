require_relative "../../spec_helper"

RSpec.describe ComplianceDomain::Exemption::Commands::RequestExemption do
  describe "attributes" do
    subject(:command) { described_class.new(
          model_id: "example",
          policy_id: "ref-id-123",
          requirement: "example",
          reason: "example"
        ) }

    it "has model_id" do
      expect(command.model_id).to eq("example")
    end

    it "has policy_id" do
      expect(command.policy_id).to eq("ref-id-123")
    end

    it "has requirement" do
      expect(command.requirement).to eq("example")
    end

    it "has reason" do
      expect(command.reason).to eq("example")
    end

  end

  describe "event" do
    it "emits RequestedExemption" do
      expect(described_class.event_name).to eq("RequestedExemption")
    end
  end

  describe "execution" do
    before { @app = Hecks.load(domain, force: true) }

    it "persists the aggregate" do
      result = Exemption.request(
          model_id: "example",
          policy_id: "ref-id-123",
          requirement: "example",
          reason: "example"
        )
      expect(result).not_to be_nil
      expect(Exemption.find(result.id)).not_to be_nil
    end

    it "emits RequestedExemption to the event log" do
      Exemption.request(
          model_id: "example",
          policy_id: "ref-id-123",
          requirement: "example",
          reason: "example"
        )
      event_names = @app.events.map { |e| e.class.name.split("::").last }
      expect(event_names).to include("RequestedExemption")
    end
  end
end
