require_relative "../../spec_helper"

RSpec.describe OperationsDomain::Deployment::Specifications::CustomerFacing do
  it "responds to satisfied_by?" do
    expect(described_class).to respond_to(:satisfied_by?)
  end

  it "returns a boolean for a sample object" do
    obj = OpenStruct.new(model_id: "example", environment: "development", endpoint: "example", purpose: "example", audience: "internal", deployed_at: DateTime.now, decommissioned_at: DateTime.now, status: "example")
    result = described_class.satisfied_by?(obj)
    expect([true, false]).to include(result)
  end
end
