require_relative "../spec_helper"

RSpec.describe IdentityDomain::Stakeholder do
  describe "creating a Stakeholder" do
    subject(:stakeholder) { described_class.new(
          name: "example",
          email: "example",
          role: "assessor",
          team: "example",
          status: "example"
        ) }

    it "assigns an id" do
      expect(stakeholder.id).not_to be_nil
    end

    it "sets name" do
      expect(stakeholder.name).to eq("example")
    end

    it "sets email" do
      expect(stakeholder.email).to eq("example")
    end

    it "sets role" do
      expect(stakeholder.role).to eq("assessor")
    end

    it "sets team" do
      expect(stakeholder.team).to eq("example")
    end

    it "sets status" do
      expect(stakeholder.status).to eq("example")
    end
  end

  describe "name validation" do
    it "rejects nil name" do
      expect {
        described_class.new(
          name: nil,
          email: "example",
          role: "assessor",
          team: "example",
          status: "example"
        )
      }.to raise_error(IdentityDomain::ValidationError, /name/)
    end
  end

  describe "email validation" do
    it "rejects nil email" do
      expect {
        described_class.new(
          name: "example",
          email: nil,
          role: "assessor",
          team: "example",
          status: "example"
        )
      }.to raise_error(IdentityDomain::ValidationError, /email/)
    end
  end

  describe "identity" do
    it "two Stakeholders with the same id are equal" do
      id = SecureRandom.uuid
      a = described_class.new(
          name: "example",
          email: "example",
          role: "assessor",
          team: "example",
          status: "example",
          id: id
        )
      b = described_class.new(
          name: "example",
          email: "example",
          role: "assessor",
          team: "example",
          status: "example",
          id: id
        )
      expect(a).to eq(b)
    end

    it "two Stakeholders with different ids are not equal" do
      a = described_class.new(
          name: "example",
          email: "example",
          role: "assessor",
          team: "example",
          status: "example"
        )
      b = described_class.new(
          name: "example",
          email: "example",
          role: "assessor",
          team: "example",
          status: "example"
        )
      expect(a).not_to eq(b)
    end
  end
end
