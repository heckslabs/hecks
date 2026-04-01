require_relative "../../spec_helper"

RSpec.describe OperationsDomain::Incident::Specifications::Critical do
  it "responds to satisfied_by?" do
    expect(described_class).to respond_to(:satisfied_by?)
  end

  it "returns a boolean for a sample object" do
    obj = OpenStruct.new(model_id: "example", severity: "low", category: "bias", description: "example", reported_by_id: "example", reported_at: DateTime.now, resolved_at: DateTime.now, resolution: "example", root_cause: "example", status: "example")
    result = described_class.satisfied_by?(obj)
    expect([true, false]).to include(result)
  end
end
