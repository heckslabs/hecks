require_relative "../spec_helper"

RSpec.describe BankingDomain::Customer do
  describe "creating a Customer" do
    subject(:customer) { described_class.new(
          name: "example",
          email: "example",
          status: "example"
        ) }

    it "assigns an id" do
      expect(customer.id).not_to be_nil
    end

    it "sets name" do
      expect(customer.name).to eq("example")
    end

    it "sets email" do
      expect(customer.email).to eq("example")
    end

    it "sets status" do
      expect(customer.status).to eq("example")
    end
  end

  describe "name validation" do
    it "rejects nil name" do
      expect {
        described_class.new(
          name: nil,
          email: "example",
          status: "example"
        )
      }.to raise_error(BankingDomain::ValidationError, /name/)
    end
  end

  describe "email validation" do
    it "rejects nil email" do
      expect {
        described_class.new(
          name: "example",
          email: nil,
          status: "example"
        )
      }.to raise_error(BankingDomain::ValidationError, /email/)
    end
  end

  describe "identity" do
    it "two Customers with the same id are equal" do
      id = SecureRandom.uuid
      a = described_class.new(
          name: "example",
          email: "example",
          status: "example",
          id: id
        )
      b = described_class.new(
          name: "example",
          email: "example",
          status: "example",
          id: id
        )
      expect(a).to eq(b)
    end

    it "two Customers with different ids are not equal" do
      a = described_class.new(
          name: "example",
          email: "example",
          status: "example"
        )
      b = described_class.new(
          name: "example",
          email: "example",
          status: "example"
        )
      expect(a).not_to eq(b)
    end
  end
end
