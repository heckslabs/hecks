require_relative "../../spec_helper"

RSpec.describe "AiModel.approved" do
  before { @app = Hecks.load(domain, force: true) }

  it "returns only AiModels matching status: "approved"" do
    AiModel.register(name: "example", version: "example", provider_id: "ref-id-123", description: "example")
    AiModel.register(name: "example", version: "example", provider_id: "ref-id-123", description: "example")
    results = AiModel.approved
    expect(results).to be_an(Array)
    expect(results.all? { |r| r.status == "approved" }).to be true
  end
end
