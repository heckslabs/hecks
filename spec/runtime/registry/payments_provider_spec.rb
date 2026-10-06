require "spec_helper"
require_relative "../../support/memory_ports"

# rust/host reads ir.json's `payments` key, so the `provides "payments"` row behind it is held
# to its contract; a domain with no such chapter exports nothing.
RSpec.describe "payments capability" do
  PAYMENTS_EXPORT = {
    provider:  "Payments",
    initiate:  "Payments::Payment.Initiate",
    succeeded: "Payments::Payment.PaymentGateway.Succeeded",
    failed:    "Payments::Payment.PaymentGateway.Failed",
    aggregate: "Payments::Payment"
  }.freeze

  let(:full_row) do
    {
      initiate:  "Payment.Initiate",
      succeeded: "Payment.PaymentGateway.Succeeded",
      failed:    "Payment.PaymentGateway.Failed"
    }
  end

  PAYMENT_AGGREGATE_BODY = proc do
    identified_by :reference
    attribute :reference, Reference
    value_object "Reference" do
      attribute :value, String
    end
    command "Initiate" do
      goal "initiate"
      attribute :reference, Reference
      sets :reference
    end
  end

  def payments_chapter(provides)
    Hecks.bluebook "Payments" do
      vision "probe"
      supporting
      provides "payments", **provides
      aggregate "Payment", &PAYMENT_AGGREGATE_BODY
    end
  end

  def gateway_body(operations)
    proc do
      operations.each do |name|
        operation name do
          attribute :note, String
          emits "Payment#{name}"
        end
      end
    end
  end

  def payments_hecksagon(operations)
    gateway = gateway_body(operations)
    Hecks.hecksagon("Payments") do
      Payments::Payment.persisted_by("Memory")
      Payments::Payment.port "PaymentGateway", &gateway
    end
  end

  def registry_with_payments(provides: full_row, operations: %w[Succeeded Failed])
    registry = Hecks::Runtime::Registry.new
    Hecks.with_registry(registry) do
      MemoryPorts.load!
      payments_chapter(provides)
      payments_hecksagon(operations)
    end
    registry
  end

  it "resolves the chapter that provides payments, whatever it is named" do
    registry = registry_with_payments

    expect(registry.payments_provider_for("Payments").name).to eq("Payments")
  end

  it "exports the declared verbs qualified, with the paying aggregate named off initiate" do
    exported = Hecks::Projector::Exporter.payments(registry_with_payments, "Payments")

    expect(exported).to eq(PAYMENTS_EXPORT)
  end

  it "boots when the hecksagon declares both processor verdicts" do
    expect { registry_with_payments.verify! }.not_to raise_error
  end

  it "refuses at verify! when the hecksagon lacks a declared verdict" do
    registry = registry_with_payments(operations: %w[Succeeded])

    expect { registry.verify! }
      .to raise_error(Hecks::Runtime::WiringError, /Payments provides "payments" failed.*no such port operation/)
  end

  it "exports nothing for a domain that attaches no payments provider" do
    registry = Hecks::Runtime::Registry.new

    expect(Hecks::Projector::Exporter.payments(registry, "Pizzas")).to eq({})
  end

  it "refuses a provides row that leaves out a key the contract needs" do
    expect { registry_with_payments(provides: { initiate: "Payment.Initiate" }) }
      .to raise_error(Hecks::Bluebook::DSL::Malformed, /payments needs exactly/)
  end

  it "refuses an initiate verb that names no command the chapter declares" do
    expect { registry_with_payments(provides: full_row.merge(initiate: "Payment.Begin")) }
      .to raise_error(Hecks::Bluebook::DSL::Malformed, /Payment\.Begin/)
  end
end
