require_relative "../spec_helper"

RSpec.describe OperationsDomain::Deployment do
  describe "creating a Deployment" do
    subject(:deployment) { described_class.new(
          model_id: "example",
          environment: "development",
          endpoint: "example",
          purpose: "example",
          audience: "internal",
          deployed_at: DateTime.now,
          decommissioned_at: DateTime.now,
          status: "example"
        ) }

    it "assigns an id" do
      expect(deployment.id).not_to be_nil
    end

    it "sets model_id" do
      expect(deployment.model_id).to eq("example")
    end

    it "sets environment" do
      expect(deployment.environment).to eq("development")
    end

    it "sets endpoint" do
      expect(deployment.endpoint).to eq("example")
    end

    it "sets purpose" do
      expect(deployment.purpose).to eq("example")
    end

    it "sets audience" do
      expect(deployment.audience).to eq("internal")
    end

    it "sets deployed_at" do
      expect(deployment.deployed_at).not_to be_nil
    end

    it "sets decommissioned_at" do
      expect(deployment.decommissioned_at).not_to be_nil
    end

    it "sets status" do
      expect(deployment.status).to eq("example")
    end
  end

  describe "model_id validation" do
    it "rejects nil model_id" do
      expect {
        described_class.new(
          model_id: nil,
          environment: "development",
          endpoint: "example",
          purpose: "example",
          audience: "internal",
          deployed_at: DateTime.now,
          decommissioned_at: DateTime.now,
          status: "example"
        )
      }.to raise_error(OperationsDomain::ValidationError, /model_id/)
    end
  end

  describe "environment validation" do
    it "rejects nil environment" do
      expect {
        described_class.new(
          model_id: "example",
          environment: nil,
          endpoint: "example",
          purpose: "example",
          audience: "internal",
          deployed_at: DateTime.now,
          decommissioned_at: DateTime.now,
          status: "example"
        )
      }.to raise_error(OperationsDomain::ValidationError, /environment/)
    end
  end

  describe "identity" do
    it "two Deployments with the same id are equal" do
      id = SecureRandom.uuid
      a = described_class.new(
          model_id: "example",
          environment: "development",
          endpoint: "example",
          purpose: "example",
          audience: "internal",
          deployed_at: DateTime.now,
          decommissioned_at: DateTime.now,
          status: "example",
          id: id
        )
      b = described_class.new(
          model_id: "example",
          environment: "development",
          endpoint: "example",
          purpose: "example",
          audience: "internal",
          deployed_at: DateTime.now,
          decommissioned_at: DateTime.now,
          status: "example",
          id: id
        )
      expect(a).to eq(b)
    end

    it "two Deployments with different ids are not equal" do
      a = described_class.new(
          model_id: "example",
          environment: "development",
          endpoint: "example",
          purpose: "example",
          audience: "internal",
          deployed_at: DateTime.now,
          decommissioned_at: DateTime.now,
          status: "example"
        )
      b = described_class.new(
          model_id: "example",
          environment: "development",
          endpoint: "example",
          purpose: "example",
          audience: "internal",
          deployed_at: DateTime.now,
          decommissioned_at: DateTime.now,
          status: "example"
        )
      expect(a).not_to eq(b)
    end
  end
end
