require_relative "../../spec_helper"

RSpec.describe OperationsDomain::Monitoring::Commands::RecordMetric do
  describe "attributes" do
    subject(:command) { described_class.new(
          model_id: "example",
          deployment_id: "ref-id-123",
          metric_name: "example",
          value: 1.0,
          threshold: 1.0
        ) }

    it "has model_id" do
      expect(command.model_id).to eq("example")
    end

    it "has deployment_id" do
      expect(command.deployment_id).to eq("ref-id-123")
    end

    it "has metric_name" do
      expect(command.metric_name).to eq("example")
    end

    it "has value" do
      expect(command.value).to eq(1.0)
    end

    it "has threshold" do
      expect(command.threshold).to eq(1.0)
    end

  end

  describe "event" do
    it "emits RecordedMetric" do
      expect(described_class.event_name).to eq("RecordedMetric")
    end
  end

  describe "execution" do
    before { @app = Hecks.load(domain, force: true) }

    it "persists the aggregate" do
      result = Monitoring.record_metric(
          model_id: "example",
          deployment_id: "ref-id-123",
          metric_name: "example",
          value: 1.0,
          threshold: 1.0
        )
      expect(result).not_to be_nil
      expect(Monitoring.find(result.id)).not_to be_nil
    end

    it "emits RecordedMetric to the event log" do
      Monitoring.record_metric(
          model_id: "example",
          deployment_id: "ref-id-123",
          metric_name: "example",
          value: 1.0,
          threshold: 1.0
        )
      event_names = @app.events.map { |e| e.class.name.split("::").last }
      expect(event_names).to include("RecordedMetric")
    end
  end
end
