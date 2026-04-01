require_relative "../../spec_helper"

RSpec.describe OperationsDomain::Deployment::Events::DecommissionedDeployment do
  subject(:event) { described_class.new(
          aggregate_id: "example",
          deployment_id: "example",
          model_id: "example",
          environment: "development",
          endpoint: "example",
          purpose: "example",
          audience: "internal",
          deployed_at: DateTime.now,
          decommissioned_at: DateTime.now,
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

  it "carries deployment_id" do
    expect(event.deployment_id).to eq("example")
  end

  it "carries model_id" do
    expect(event.model_id).to eq("example")
  end

  it "carries environment" do
    expect(event.environment).to eq("development")
  end

  it "carries endpoint" do
    expect(event.endpoint).to eq("example")
  end

  it "carries purpose" do
    expect(event.purpose).to eq("example")
  end

  it "carries audience" do
    expect(event.audience).to eq("internal")
  end

  it "carries deployed_at" do
    expect(event.deployed_at).not_to be_nil
  end

  it "carries decommissioned_at" do
    expect(event.decommissioned_at).not_to be_nil
  end

  it "carries status" do
    expect(event.status).to eq("example")
  end
end
