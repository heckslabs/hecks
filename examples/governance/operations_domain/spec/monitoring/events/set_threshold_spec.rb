require_relative "../../spec_helper"

RSpec.describe OperationsDomain::Monitoring::Events::SetThreshold do
  subject(:event) { described_class.new(
          aggregate_id: "example",
          monitoring_id: "example",
          threshold: 1.0,
          model_id: "example",
          deployment_id: "ref-id-123",
          metric_name: "example",
          value: 1.0,
          recorded_at: DateTime.now
        ) }

  it "is frozen" do
    expect(event).to be_frozen
  end

  it "records when it occurred" do
    expect(event.occurred_at).to be_a(Time)
  end

  it "carries aggregate_id" do
    expect(event.aggregate_id).to eq("example")
  end

  it "carries monitoring_id" do
    expect(event.monitoring_id).to eq("example")
  end

  it "carries threshold" do
    expect(event.threshold).to eq(1.0)
  end

  it "carries model_id" do
    expect(event.model_id).to eq("example")
  end

  it "carries deployment_id" do
    expect(event.deployment_id).to eq("ref-id-123")
  end

  it "carries metric_name" do
    expect(event.metric_name).to eq("example")
  end

  it "carries value" do
    expect(event.value).to eq(1.0)
  end

  it "carries recorded_at" do
    expect(event.recorded_at).not_to be_nil
  end
end
