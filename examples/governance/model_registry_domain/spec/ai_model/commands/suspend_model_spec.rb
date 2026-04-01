require_relative "../../spec_helper"

RSpec.describe ModelRegistryDomain::AiModel::Commands::SuspendModel do
  describe "attributes" do
    subject(:command) { described_class.new(model_id: "example") }

    it "has model_id" do
      expect(command.model_id).to eq("example")
    end

  end

  describe "event" do
    it "emits SuspendedModel" do
      expect(described_class.event_name).to eq("SuspendedModel")
    end
  end

  describe "execution" do
    before { @app = Hecks.load(domain, force: true) }

    it "updates the aggregate and emits SuspendedModel" do
      agg = AiModel.register(
          name: "example",
          version: "example",
          provider_id: "ref-id-123",
          description: "example"
        )
      AiModel.suspend(model_id: "example")
      event_names = @app.events.map { |e| e.class.name.split("::").last }
      expect(event_names).to include("SuspendedModel")
    end
  end
end
