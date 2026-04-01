require_relative "../../spec_helper"

RSpec.describe OperationsDomain::Monitoring::Specifications::ThresholdBreached do
  it "responds to satisfied_by?" do
    expect(described_class).to respond_to(:satisfied_by?)
  end

  it "returns a boolean for a sample object" do
    obj = OpenStruct.new(model_id: "example", deployment_id: "ref-id-123", metric_name: "example", value: 1.0, threshold: 1.0, recorded_at: DateTime.now)
    result = described_class.satisfied_by?(obj)
    expect([true, false]).to include(result)
  end
end
