require_relative "../spec_helper"

RSpec.describe OperationsDomain::Monitoring do
  describe "creating a Monitoring" do
    subject(:monitoring) { described_class.new(
          model_id: "example",
          deployment_id: "ref-id-123",
          metric_name: "example",
          value: 1.0,
          threshold: 1.0,
          recorded_at: DateTime.now
        ) }

    it "assigns an id" do
      expect(monitoring.id).not_to be_nil
    end

    it "sets model_id" do
      expect(monitoring.model_id).to eq("example")
    end

    it "sets deployment_id" do
      expect(monitoring.deployment_id).to eq("ref-id-123")
    end

    it "sets metric_name" do
      expect(monitoring.metric_name).to eq("example")
    end

    it "sets value" do
      expect(monitoring.value).to eq(1.0)
    end

    it "sets threshold" do
      expect(monitoring.threshold).to eq(1.0)
    end

    it "sets recorded_at" do
      expect(monitoring.recorded_at).not_to be_nil
    end
  end

  describe "model_id validation" do
    it "rejects nil model_id" do
      expect {
        described_class.new(
          model_id: nil,
          deployment_id: "ref-id-123",
          metric_name: "example",
          value: 1.0,
          threshold: 1.0,
          recorded_at: DateTime.now
        )
      }.to raise_error(OperationsDomain::ValidationError, /model_id/)
    end
  end

  describe "metric_name validation" do
    it "rejects nil metric_name" do
      expect {
        described_class.new(
          model_id: "example",
          deployment_id: "ref-id-123",
          metric_name: nil,
          value: 1.0,
          threshold: 1.0,
          recorded_at: DateTime.now
        )
      }.to raise_error(OperationsDomain::ValidationError, /metric_name/)
    end
  end

  describe "invariant: threshold must be positive" do
    it "raises InvariantError when violated" do
      # TODO: construct an instance that violates: threshold must be positive
      # expect { described_class.new(...) }.to raise_error(OperationsDomain::InvariantError)
    end
  end

  describe "identity" do
    it "two Monitorings with the same id are equal" do
      id = SecureRandom.uuid
      a = described_class.new(
          model_id: "example",
          deployment_id: "ref-id-123",
          metric_name: "example",
          value: 1.0,
          threshold: 1.0,
          recorded_at: DateTime.now,
          id: id
        )
      b = described_class.new(
          model_id: "example",
          deployment_id: "ref-id-123",
          metric_name: "example",
          value: 1.0,
          threshold: 1.0,
          recorded_at: DateTime.now,
          id: id
        )
      expect(a).to eq(b)
    end

    it "two Monitorings with different ids are not equal" do
      a = described_class.new(
          model_id: "example",
          deployment_id: "ref-id-123",
          metric_name: "example",
          value: 1.0,
          threshold: 1.0,
          recorded_at: DateTime.now
        )
      b = described_class.new(
          model_id: "example",
          deployment_id: "ref-id-123",
          metric_name: "example",
          value: 1.0,
          threshold: 1.0,
          recorded_at: DateTime.now
        )
      expect(a).not_to eq(b)
    end
  end
end
