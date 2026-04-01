require_relative "../../spec_helper"

RSpec.describe ModelRegistryDomain::DataUsageAgreement::Specifications::Expired do
  it "responds to satisfied_by?" do
    expect(described_class).to respond_to(:satisfied_by?)
  end

  it "returns a boolean for a sample object" do
    obj = OpenStruct.new(model_id: "ref-id-123", data_source: "example", purpose: "example", consent_type: "public_domain", effective_date: Date.today, expiration_date: Date.today, restrictions: [], status: "example")
    result = described_class.satisfied_by?(obj)
    expect([true, false]).to include(result)
  end
end
