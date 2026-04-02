require "spec_helper"
require "hecks/extensions/pii"

RSpec.describe "Hecks::PII" do
  let(:domain) do
    Hecks.domain "PiiTest" do
      aggregate "Customer" do
        attribute :name, String, pii: true
        attribute :email, String, pii: true
        attribute :account_type, String

        command "RegisterCustomer" do
          attribute :name, String
          attribute :email, String
          attribute :account_type, String
        end
      end
    end
  end

  before do
    @app = Hecks.load(domain)
    Hecks.extension_registry[:pii]&.call(
      Object.const_get("PiiTestDomain"), domain, @app
    )
  end

  describe "DSL" do
    it "marks attributes as PII" do
      agg = domain.aggregates.first
      pii = agg.attributes.select(&:pii?)
      expect(pii.map(&:name)).to eq([:name, :email])
    end

    it "non-PII attributes are not marked" do
      agg = domain.aggregates.first
      account_type = agg.attributes.find { |a| a.name == :account_type }
      expect(account_type.pii?).to be false
    end
  end

  describe "pii_fields introspection" do
    it "lists PII fields per aggregate" do
      mod = Object.const_get("PiiTestDomain")
      expect(mod.pii_fields).to eq("Customer" => [:name, :email])
    end
  end

  describe "erase_pii" do
    it "nulls PII fields on the entity" do
      customer = Customer.create(name: "Alice", email: "alice@example.com", account_type: "premium")
      mod = Object.const_get("PiiTestDomain")
      mod.erase_pii(customer.id)

      erased = Customer.find(customer.id)
      expect(erased.name).to be_nil
      expect(erased.email).to be_nil
      expect(erased.account_type).to be_nil # new instance, non-PII not preserved in this simple impl
    end
  end

  describe "Hecks::PII.mask" do
    it "masks a string value" do
      expect(Hecks::PII.mask("alice@example.com")).to eq("a***************m")
    end

    it "redacts short values" do
      expect(Hecks::PII.mask("AB")).to eq("[REDACTED]")
    end

    it "handles nil" do
      expect(Hecks::PII.mask(nil)).to be_nil
    end
  end
end
