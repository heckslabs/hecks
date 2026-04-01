require_relative "../../spec_helper"

RSpec.describe ModelRegistryDomain::AiModel::Commands::ApproveModel do
  describe "attributes" do
    subject(:command) { described_class.new(model_id: "example") }

    it "has model_id" do
      expect(command.model_id).to eq("example")
    end

  end

  describe "event" do
    it "emits ApprovedModel" do
      expect(described_class.event_name).to eq("ApprovedModel")
    end
  end

  describe "execution" do
    before { @app = Hecks.load(domain, force: true) }

    it "updates the aggregate and emits ApprovedModel" do
      agg = AiModel.register(
          name: "example",
          version: "example",
          provider_id: "ref-id-123",
          description: "example"
        )
      AiModel.approve(model_id: "example")
      event_names = @app.events.map { |e| e.class.name.split("::").last }
      expect(event_names).to include("ApprovedModel")
    end
  end
end
