require_relative "../../spec_helper"

RSpec.describe ModelRegistryDomain::DataUsageAgreement::Events::RevokedAgreement do
  subject(:event) { described_class.new(
          aggregate_id: "example",
          agreement_id: "example",
          model_id: "ref-id-123",
          data_source: "example",
          purpose: "example",
          consent_type: "public_domain",
          effective_date: Date.today,
          expiration_date: Date.today,
          restrictions: [],
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

  it "carries agreement_id" do
    expect(event.agreement_id).to eq("example")
  end

  it "carries model_id" do
    expect(event.model_id).to eq("ref-id-123")
  end

  it "carries data_source" do
    expect(event.data_source).to eq("example")
  end

  it "carries purpose" do
    expect(event.purpose).to eq("example")
  end

  it "carries consent_type" do
    expect(event.consent_type).to eq("public_domain")
  end

  it "carries effective_date" do
    expect(event.effective_date).not_to be_nil
  end

  it "carries expiration_date" do
    expect(event.expiration_date).not_to be_nil
  end

  it "carries restrictions" do
    expect(event.restrictions).to eq([])
  end

  it "carries status" do
    expect(event.status).to eq("example")
  end
end
