require_relative "../../spec_helper"

RSpec.describe ModelRegistryDomain::AiModel::Commands::DeriveModel do
  describe "attributes" do
    subject(:command) { described_class.new(
          name: "example",
          version: "example",
          parent_model_id: "example",
          derivation_type: "example",
          description: "example"
        ) }

    it "has name" do
      expect(command.name).to eq("example")
    end

    it "has version" do
      expect(command.version).to eq("example")
    end

    it "has parent_model_id" do
      expect(command.parent_model_id).to eq("example")
    end

    it "has derivation_type" do
      expect(command.derivation_type).to eq("example")
    end

    it "has description" do
      expect(command.description).to eq("example")
    end

  end

  describe "event" do
    it "emits DerivedModel" do
      expect(described_class.event_name).to eq("DerivedModel")
    end
  end

  describe "execution" do
    before { @app = Hecks.load(domain, force: true) }

    it "persists the aggregate" do
      result = AiModel.derive(
          name: "example",
          version: "example",
          parent_model_id: "example",
          derivation_type: "example",
          description: "example"
        )
      expect(result).not_to be_nil
      expect(AiModel.find(result.id)).not_to be_nil
    end

    it "emits DerivedModel to the event log" do
      AiModel.derive(
          name: "example",
          version: "example",
          parent_model_id: "example",
          derivation_type: "example",
          description: "example"
        )
      event_names = @app.events.map { |e| e.class.name.split("::").last }
      expect(event_names).to include("DerivedModel")
    end
  end
end
