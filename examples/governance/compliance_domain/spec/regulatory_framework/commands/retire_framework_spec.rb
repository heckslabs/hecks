require_relative "../../spec_helper"

RSpec.describe ComplianceDomain::RegulatoryFramework::Commands::RetireFramework do
  describe "attributes" do
    subject(:command) { described_class.new(framework_id: "example") }

    it "has framework_id" do
      expect(command.framework_id).to eq("example")
    end

  end

  describe "event" do
    it "emits RetiredFramework" do
      expect(described_class.event_name).to eq("RetiredFramework")
    end
  end

  describe "execution" do
    before { @app = Hecks.load(domain, force: true) }

    it "updates the aggregate and emits RetiredFramework" do
      agg = RegulatoryFramework.register(
          name: "example",
          jurisdiction: "example",
          version: "example",
          authority: "example"
        )
      RegulatoryFramework.retire(framework_id: "example")
      event_names = @app.events.map { |e| e.class.name.split("::").last }
      expect(event_names).to include("RetiredFramework")
    end
  end
end
