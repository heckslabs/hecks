require_relative "../spec_helper"

RSpec.describe OperationsDomain::Incident do
  describe "creating a Incident" do
    subject(:incident) { described_class.new(
          model_id: "example",
          severity: "low",
          category: "bias",
          description: "example",
          reported_by_id: "example",
          reported_at: DateTime.now,
          resolved_at: DateTime.now,
          resolution: "example",
          root_cause: "example",
          status: "example"
        ) }

    it "assigns an id" do
      expect(incident.id).not_to be_nil
    end

    it "sets model_id" do
      expect(incident.model_id).to eq("example")
    end

    it "sets severity" do
      expect(incident.severity).to eq("low")
    end

    it "sets category" do
      expect(incident.category).to eq("bias")
    end

    it "sets description" do
      expect(incident.description).to eq("example")
    end

    it "sets reported_by_id" do
      expect(incident.reported_by_id).to eq("example")
    end

    it "sets reported_at" do
      expect(incident.reported_at).not_to be_nil
    end

    it "sets resolved_at" do
      expect(incident.resolved_at).not_to be_nil
    end

    it "sets resolution" do
      expect(incident.resolution).to eq("example")
    end

    it "sets root_cause" do
      expect(incident.root_cause).to eq("example")
    end

    it "sets status" do
      expect(incident.status).to eq("example")
    end
  end

  describe "model_id validation" do
    it "rejects nil model_id" do
      expect {
        described_class.new(
          model_id: nil,
          severity: "low",
          category: "bias",
          description: "example",
          reported_by_id: "example",
          reported_at: DateTime.now,
          resolved_at: DateTime.now,
          resolution: "example",
          root_cause: "example",
          status: "example"
        )
      }.to raise_error(OperationsDomain::ValidationError, /model_id/)
    end
  end

  describe "severity validation" do
    it "rejects nil severity" do
      expect {
        described_class.new(
          model_id: "example",
          severity: nil,
          category: "bias",
          description: "example",
          reported_by_id: "example",
          reported_at: DateTime.now,
          resolved_at: DateTime.now,
          resolution: "example",
          root_cause: "example",
          status: "example"
        )
      }.to raise_error(OperationsDomain::ValidationError, /severity/)
    end
  end

  describe "identity" do
    it "two Incidents with the same id are equal" do
      id = SecureRandom.uuid
      a = described_class.new(
          model_id: "example",
          severity: "low",
          category: "bias",
          description: "example",
          reported_by_id: "example",
          reported_at: DateTime.now,
          resolved_at: DateTime.now,
          resolution: "example",
          root_cause: "example",
          status: "example",
          id: id
        )
      b = described_class.new(
          model_id: "example",
          severity: "low",
          category: "bias",
          description: "example",
          reported_by_id: "example",
          reported_at: DateTime.now,
          resolved_at: DateTime.now,
          resolution: "example",
          root_cause: "example",
          status: "example",
          id: id
        )
      expect(a).to eq(b)
    end

    it "two Incidents with different ids are not equal" do
      a = described_class.new(
          model_id: "example",
          severity: "low",
          category: "bias",
          description: "example",
          reported_by_id: "example",
          reported_at: DateTime.now,
          resolved_at: DateTime.now,
          resolution: "example",
          root_cause: "example",
          status: "example"
        )
      b = described_class.new(
          model_id: "example",
          severity: "low",
          category: "bias",
          description: "example",
          reported_by_id: "example",
          reported_at: DateTime.now,
          resolved_at: DateTime.now,
          resolution: "example",
          root_cause: "example",
          status: "example"
        )
      expect(a).not_to eq(b)
    end
  end
end
