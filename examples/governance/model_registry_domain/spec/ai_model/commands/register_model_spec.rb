require_relative "../../spec_helper"

RSpec.describe ModelRegistryDomain::AiModel::Commands::RegisterModel do
  describe "attributes" do
    subject(:command) { described_class.new(
          name: "example",
          version: "example",
          provider_id: "ref-id-123",
          description: "example"
        ) }

    it "has name" do
      expect(command.name).to eq("example")
    end

    it "has version" do
      expect(command.version).to eq("example")
    end

    it "has provider_id" do
      expect(command.provider_id).to eq("ref-id-123")
    end

    it "has description" do
      expect(command.description).to eq("example")
    end

  end

  describe "event" do
    it "emits RegisteredModel" do
      expect(described_class.event_name).to eq("RegisteredModel")
    end
  end

  describe "execution" do
    before { @app = Hecks.load(domain, force: true) }

    it "persists the aggregate" do
      result = AiModel.register(
          name: "example",
          version: "example",
          provider_id: "ref-id-123",
          description: "example"
        )
      expect(result).not_to be_nil
      expect(AiModel.find(result.id)).not_to be_nil
    end

    it "emits RegisteredModel to the event log" do
      AiModel.register(
          name: "example",
          version: "example",
          provider_id: "ref-id-123",
          description: "example"
        )
      event_names = @app.events.map { |e| e.class.name.split("::").last }
      expect(event_names).to include("RegisteredModel")
    end
  end
end
