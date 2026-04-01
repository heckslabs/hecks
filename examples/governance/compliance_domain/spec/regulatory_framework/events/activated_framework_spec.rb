require_relative "../../spec_helper"

RSpec.describe ComplianceDomain::RegulatoryFramework::Events::ActivatedFramework do
  subject(:event) { described_class.new(
          aggregate_id: "example",
          framework_id: "example",
          effective_date: Date.today,
          name: "example",
          jurisdiction: "example",
          version: "example",
          authority: "example",
          requirements: [],
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

  it "carries framework_id" do
    expect(event.framework_id).to eq("example")
  end

  it "carries effective_date" do
    expect(event.effective_date).not_to be_nil
  end

  it "carries name" do
    expect(event.name).to eq("example")
  end

  it "carries jurisdiction" do
    expect(event.jurisdiction).to eq("example")
  end

  it "carries version" do
    expect(event.version).to eq("example")
  end

  it "carries authority" do
    expect(event.authority).to eq("example")
  end

  it "carries requirements" do
    expect(event.requirements).to eq([])
  end

  it "carries status" do
    expect(event.status).to eq("example")
  end
end
