require_relative "../spec_helper"

RSpec.describe "ModelApproval workflow" do
  before { @app = Hecks.load(domain, force: true) }

  it "is callable" do
    expect(ModelRegistryDomain).to respond_to(:model_approval)
  end
end
