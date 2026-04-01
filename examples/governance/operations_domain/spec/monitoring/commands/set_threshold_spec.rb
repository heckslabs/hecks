require_relative "../../spec_helper"

RSpec.describe OperationsDomain::Monitoring::Commands::SetThreshold do
  describe "attributes" do
    subject(:command) { described_class.new(monitoring_id: "example", threshold: 1.0) }

    it "has monitoring_id" do
      expect(command.monitoring_id).to eq("example")
    end

    it "has threshold" do
      expect(command.threshold).to eq(1.0)
    end

  end

  describe "event" do
    it "emits SetThreshold" do
      expect(described_class.event_name).to eq("SetThreshold")
    end
  end

  describe "execution" do
    before { @app = Hecks.load(domain, force: true) }

    it "updates the aggregate and emits SetThreshold" do
      agg = Monitoring.record_metric(
          model_id: "example",
          deployment_id: "ref-id-123",
          metric_name: "example",
          value: 1.0,
          threshold: 1.0
        )
      Monitoring.set_threshold(monitoring_id: "example", threshold: 1.0)
      event_names = @app.events.map { |e| e.class.name.split("::").last }
      expect(event_names).to include("SetThreshold")
    end
  end
end
