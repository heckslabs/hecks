require_relative "../../spec_helper"

RSpec.describe IdentityDomain::Stakeholder::Events::RegisteredStakeholder do
  subject(:event) { described_class.new(
          aggregate_id: "example",
          name: "example",
          email: "example",
          role: "example",
          team: "example",
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

  it "carries name" do
    expect(event.name).to eq("example")
  end

  it "carries email" do
    expect(event.email).to eq("example")
  end

  it "carries role" do
    expect(event.role).to eq("example")
  end

  it "carries team" do
    expect(event.team).to eq("example")
  end

  it "carries status" do
    expect(event.status).to eq("example")
  end
end
