require_relative "../spec_helper"

RSpec.describe IdentityDomain::AuditLog do
  describe "creating a AuditLog" do
    subject(:audit_log) { described_class.new(
          entity_type: "example",
          entity_id: "example",
          action: "example",
          actor_id: "ref-id-123",
          details: "example",
          timestamp: DateTime.now
        ) }

    it "assigns an id" do
      expect(audit_log.id).not_to be_nil
    end

    it "sets entity_type" do
      expect(audit_log.entity_type).to eq("example")
    end

    it "sets entity_id" do
      expect(audit_log.entity_id).to eq("example")
    end

    it "sets action" do
      expect(audit_log.action).to eq("example")
    end

    it "sets actor_id" do
      expect(audit_log.actor_id).to eq("ref-id-123")
    end

    it "sets details" do
      expect(audit_log.details).to eq("example")
    end

    it "sets timestamp" do
      expect(audit_log.timestamp).not_to be_nil
    end
  end

  describe "entity_type validation" do
    it "rejects nil entity_type" do
      expect {
        described_class.new(
          entity_type: nil,
          entity_id: "example",
          action: "example",
          actor_id: "ref-id-123",
          details: "example",
          timestamp: DateTime.now
        )
      }.to raise_error(IdentityDomain::ValidationError, /entity_type/)
    end
  end

  describe "action validation" do
    it "rejects nil action" do
      expect {
        described_class.new(
          entity_type: "example",
          entity_id: "example",
          action: nil,
          actor_id: "ref-id-123",
          details: "example",
          timestamp: DateTime.now
        )
      }.to raise_error(IdentityDomain::ValidationError, /action/)
    end
  end

  describe "identity" do
    it "two AuditLogs with the same id are equal" do
      id = SecureRandom.uuid
      a = described_class.new(
          entity_type: "example",
          entity_id: "example",
          action: "example",
          actor_id: "ref-id-123",
          details: "example",
          timestamp: DateTime.now,
          id: id
        )
      b = described_class.new(
          entity_type: "example",
          entity_id: "example",
          action: "example",
          actor_id: "ref-id-123",
          details: "example",
          timestamp: DateTime.now,
          id: id
        )
      expect(a).to eq(b)
    end

    it "two AuditLogs with different ids are not equal" do
      a = described_class.new(
          entity_type: "example",
          entity_id: "example",
          action: "example",
          actor_id: "ref-id-123",
          details: "example",
          timestamp: DateTime.now
        )
      b = described_class.new(
          entity_type: "example",
          entity_id: "example",
          action: "example",
          actor_id: "ref-id-123",
          details: "example",
          timestamp: DateTime.now
        )
      expect(a).not_to eq(b)
    end
  end
end
