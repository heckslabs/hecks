# Hecksagon DSL capabilities spec
#
# Tests the capabilities keyword and aggregate-level capability
# tagging in the Hecksagon DSL.
#
require "spec_helper"

RSpec.describe "Hecksagon DSL capabilities" do
  describe "domain-wide capabilities" do
    it "stores capabilities on the IR" do
      hex = Hecks.hecksagon do
        capabilities :crud, :audit
      end

      expect(hex.capabilities).to eq([:crud, :audit])
    end
  end

  describe "aggregate capability tags" do
    it "stores attribute-level tags via fluent chain" do
      hex = Hecks.hecksagon do
        aggregate "Customer" do
          capability.email.pii
          capability.ssn.pii
        end
      end

      tags = hex.aggregate_capabilities["Customer"]
      expect(tags).to include({ attribute: "email", tag: :pii })
      expect(tags).to include({ attribute: "ssn", tag: :pii })
    end

    it "supports multiple tags on different aggregates" do
      hex = Hecks.hecksagon do
        capabilities :crud

        aggregate "Customer" do
          capability.email.pii
        end

        aggregate "Order" do
          capability.total.audit
        end
      end

      expect(hex.capabilities).to eq([:crud])
      expect(hex.aggregate_capabilities["Customer"]).to eq([{ attribute: "email", tag: :pii }])
      expect(hex.aggregate_capabilities["Order"]).to eq([{ attribute: "total", tag: :audit }])
    end
  end

  describe "wired into boot" do
    it "applies domain-wide capabilities at boot" do
      domain = Hecks.domain "CapTest" do
        aggregate "Widget" do
          attribute :name, String
          command "CreateWidget" do
            attribute :name, String
          end
        end
      end

      hex = Hecks.hecksagon do
        capabilities :crud
      end

      runtime = Hecks.load(domain, hecksagon: hex)
      widget_class = Object.const_get("CapTestDomain::Widget")

      expect(widget_class).to respond_to(:find)
      expect(widget_class).to respond_to(:all)
    ensure
      Hecks.last_hecksagon = nil
      Object.send(:remove_const, :CapTestDomain) if defined?(CapTestDomain)
    end
  end
end
