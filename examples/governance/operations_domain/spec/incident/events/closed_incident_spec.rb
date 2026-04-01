require_relative "../../spec_helper"

RSpec.describe OperationsDomain::Incident::Events::ClosedIncident do
  subject(:event) { described_class.new(
          aggregate_id: "example",
          incident_id: "example",
          model_id: "example",
          severity: "low",
          category: "bias",
          description: "example",
          reported_by_id: "example",
          reported_at: DateTime.now,
          resolved_at: DateTime.now,
          resolution: "example",
          root_cause: "example",
          status: "example"
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

  it "carries incident_id" do
    expect(event.incident_id).to eq("example")
  end

  it "carries model_id" do
    expect(event.model_id).to eq("example")
  end

  it "carries severity" do
    expect(event.severity).to eq("low")
  end

  it "carries category" do
    expect(event.category).to eq("bias")
  end

  it "carries description" do
    expect(event.description).to eq("example")
  end

  it "carries reported_by_id" do
    expect(event.reported_by_id).to eq("example")
  end

  it "carries reported_at" do
    expect(event.reported_at).not_to be_nil
  end

  it "carries resolved_at" do
    expect(event.resolved_at).not_to be_nil
  end

  it "carries resolution" do
    expect(event.resolution).to eq("example")
  end

  it "carries root_cause" do
    expect(event.root_cause).to eq("example")
  end

  it "carries status" do
    expect(event.status).to eq("example")
  end
end
