require "spec_helper"
require "hecks/extensions/auth"

RSpec.describe Hecks::Runtime::AuthCoverageCheck do
  after { Hecks.actor = nil }

  context "domain with actor-protected commands and no :auth" do
    let(:domain) do
      Hecks.domain "AuthCovNone" do
        aggregate "Invoice" do
          attribute :total, Float

          command "Create" do
            actor "Admin"
            attribute :total, Float
          end

          command "Approve" do
            actor "Manager"
            attribute :invoice_id, String
          end
        end
      end
    end

    it "raises ConfigurationError naming the affected commands" do
      app = Hecks.load(domain)
      expect { app.check_auth_coverage! }.to raise_error(
        Hecks::ConfigurationError,
        /Domain 'AuthCovNone' declares actor requirements on 2 commands \(Create, Approve\)/
      )
    end
  end

  context "domain with actor-protected commands and extend :auth" do
    let(:domain) do
      Hecks.domain "AuthCovWith" do
        aggregate "Invoice" do
          attribute :total, Float

          command "Create" do
            actor "Admin"
            attribute :total, Float
          end
        end
      end
    end

    it "boots cleanly" do
      app = Hecks.load(domain)
      Hecks.extension_registry[:auth].call(
        Object.const_get("AuthCovWithDomain"), domain, app
      )
      expect { app.check_auth_coverage! }.not_to raise_error
    end
  end

  context "domain with actor-protected commands and extend :auth, enforce: false" do
    let(:domain) do
      Hecks.domain "AuthCovOptOut" do
        aggregate "Invoice" do
          attribute :total, Float

          command "Create" do
            actor "Admin"
            attribute :total, Float
          end
        end
      end
    end

    it "boots cleanly with no-op sentinel" do
      app = Hecks.load(domain)
      Hecks.extension_registry[:auth].call(
        Object.const_get("AuthCovOptOutDomain"), domain, app, enforce: false
      )
      expect { app.check_auth_coverage! }.not_to raise_error
    end

    it "does not enforce authorization" do
      app = Hecks.load(domain)
      Hecks.extension_registry[:auth].call(
        Object.const_get("AuthCovOptOutDomain"), domain, app, enforce: false
      )
      # No actor set, but should not raise
      expect { Invoice.create(total: 100.0) }.not_to raise_error
    end
  end

  context "domain with no actor requirements and no :auth" do
    let(:domain) do
      Hecks.domain "AuthCovClean" do
        aggregate "Widget" do
          attribute :name, String

          command "Create" do
            attribute :name, String
          end
        end
      end
    end

    it "boots cleanly (backward compat)" do
      app = Hecks.load(domain)
      expect { app.check_auth_coverage! }.not_to raise_error
    end
  end
end
