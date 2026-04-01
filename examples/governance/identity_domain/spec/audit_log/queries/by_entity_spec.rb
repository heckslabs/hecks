require_relative "../../spec_helper"

RSpec.describe "AuditLog.by_entity" do
  before { @app = Hecks.load(domain, force: true) }

  it "returns an Array" do
    results = AuditLog.by_entity("example")
    expect(results).to be_an(Array)
  end
end
