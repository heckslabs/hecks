require "spec_helper"

RSpec.describe Hecks::Runtime::ReferenceCoverageCheck do
  after { Hecks::Utils.cleanup_constants! }

  context "reference_to with default validate:true and no authorizer" do
    let(:domain) do
      Hecks.domain "RefCovNone" do
        aggregate "Pizza" do
          attribute :name, String

          command "CreatePizza" do
            attribute :name, String
          end
        end

        aggregate "Order" do
          attribute :quantity, Integer

          command "PlaceOrder" do
            reference_to "Pizza"
            attribute :quantity, Integer
          end
        end
      end
    end

    it "raises ConfigurationError naming the unprotected command" do
      app = Hecks.load(domain)
      expect { app.check_reference_coverage! }.to raise_error(
        Hecks::ConfigurationError,
        /Domain 'RefCovNone' declares reference_to with validate: true on 1 command \(Order#PlaceOrder\)/
      )
    end
  end

  context "reference_to with authorizer registered" do
    let(:domain) do
      Hecks.domain "RefCovWith" do
        aggregate "Pizza" do
          attribute :name, String

          command "CreatePizza" do
            attribute :name, String
          end
        end

        aggregate "Order" do
          attribute :quantity, Integer

          command "PlaceOrder" do
            reference_to "Pizza"
            attribute :quantity, Integer
          end
        end
      end
    end

    it "boots normally when reference_authorizer is set" do
      app = Hecks.load(domain)
      cmd_class = RefCovWithDomain::Order::Commands::PlaceOrder
      cmd_class.reference_authorizer = ->(_ref, _record, _cmd) { true }

      expect { app.check_reference_coverage! }.not_to raise_error

      cmd_class.reference_authorizer = nil
    end
  end

  context "reference_to with validate: :exists and no authorizer" do
    let(:domain) do
      Hecks.domain "RefCovExists" do
        aggregate "Pizza" do
          attribute :name, String

          command "CreatePizza" do
            attribute :name, String
          end
        end

        aggregate "Order" do
          attribute :quantity, Integer

          command "VerifyStock" do
            reference_to "Pizza", validate: :exists
            attribute :quantity, Integer
          end
        end
      end
    end

    it "boots normally — existence-only check needs no authorizer" do
      app = Hecks.load(domain)
      expect { app.check_reference_coverage! }.not_to raise_error
    end
  end

  context "reference_to with validate: false and no authorizer" do
    let(:domain) do
      Hecks.domain "RefCovFalse" do
        aggregate "Pizza" do
          attribute :name, String

          command "CreatePizza" do
            attribute :name, String
          end
        end

        aggregate "Order" do
          attribute :quantity, Integer

          command "DispatchOrder" do
            reference_to "Pizza", validate: false
            attribute :quantity, Integer
          end
        end
      end
    end

    it "boots normally — validation disabled, no authorizer required" do
      app = Hecks.load(domain)
      expect { app.check_reference_coverage! }.not_to raise_error
    end
  end

  context "no references at all" do
    let(:domain) do
      Hecks.domain "RefCovClean" do
        aggregate "Widget" do
          attribute :name, String

          command "Create" do
            attribute :name, String
          end
        end
      end
    end

    it "boots normally" do
      app = Hecks.load(domain)
      expect { app.check_reference_coverage! }.not_to raise_error
    end
  end
end
