require_relative "../../spec_helper"

RSpec.describe "AiModel.suspended" do
  before { @app = Hecks.load(domain, force: true) }

  it "returns only AiModels matching status: "suspended"" do
    AiModel.register(name: "example", version: "example", provider_id: "ref-id-123", description: "example")
    AiModel.register(name: "example", version: "example", provider_id: "ref-id-123", description: "example")
    results = AiModel.suspended
    expect(results).to be_an(Array)
    expect(results.all? { |r| r.status == "suspended" }).to be true
  end
end
