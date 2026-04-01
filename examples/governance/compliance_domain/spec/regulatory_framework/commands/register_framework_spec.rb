require_relative "../../spec_helper"

RSpec.describe ComplianceDomain::RegulatoryFramework::Commands::RegisterFramework do
  describe "attributes" do
    subject(:command) { described_class.new(
          name: "example",
          jurisdiction: "example",
          version: "example",
          authority: "example"
        ) }

    it "has name" do
      expect(command.name).to eq("example")
    end

    it "has jurisdiction" do
      expect(command.jurisdiction).to eq("example")
    end

    it "has version" do
      expect(command.version).to eq("example")
    end

    it "has authority" do
      expect(command.authority).to eq("example")
    end

  end

  describe "event" do
    it "emits RegisteredFramework" do
      expect(described_class.event_name).to eq("RegisteredFramework")
    end
  end

  describe "execution" do
    before { @app = Hecks.load(domain, force: true) }

    it "persists the aggregate" do
      result = RegulatoryFramework.register(
          name: "example",
          jurisdiction: "example",
          version: "example",
          authority: "example"
        )
      expect(result).not_to be_nil
      expect(RegulatoryFramework.find(result.id)).not_to be_nil
    end

    it "emits RegisteredFramework to the event log" do
      RegulatoryFramework.register(
          name: "example",
          jurisdiction: "example",
          version: "example",
          authority: "example"
        )
      event_names = @app.events.map { |e| e.class.name.split("::").last }
      expect(event_names).to include("RegisteredFramework")
    end
  end
end
