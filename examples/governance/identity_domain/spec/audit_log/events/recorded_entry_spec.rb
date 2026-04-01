require_relative "../../spec_helper"

RSpec.describe IdentityDomain::AuditLog::Events::RecordedEntry do
  subject(:event) { described_class.new(
          aggregate_id: "example",
          entity_type: "example",
          entity_id: "example",
          action: "example",
          actor_id: "ref-id-123",
          details: "example",
          timestamp: DateTime.now
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

  it "carries entity_type" do
    expect(event.entity_type).to eq("example")
  end

  it "carries entity_id" do
    expect(event.entity_id).to eq("example")
  end

  it "carries action" do
    expect(event.action).to eq("example")
  end

  it "carries actor_id" do
    expect(event.actor_id).to eq("ref-id-123")
  end

  it "carries details" do
    expect(event.details).to eq("example")
  end

  it "carries timestamp" do
    expect(event.timestamp).not_to be_nil
  end
end
