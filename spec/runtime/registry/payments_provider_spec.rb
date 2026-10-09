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

  # A payment whose lifecycle marks the states that hold a seat (ADR 0096).
  MARKED_PAYMENT_BODY = proc do
    instance_exec(&PAYMENT_AGGREGATE_BODY)
    lifecycle :status, default: "pending" do
      mark :holds_seat, "pending", "paid", "disputed"
      transition "Settle"  => "paid",     from: "pending"
      transition "Dispute" => "disputed", from: "paid"
    end
    command "Settle" do
      goal "settle"
      reference_to Payment
    end
    command "Dispute" do
      goal "dispute"
      reference_to Payment
    end
  end

  def payments_chapter(provides, body = PAYMENT_AGGREGATE_BODY)
    Hecks.bluebook "Payments" do
      vision "probe"
      supporting
      provides "payments", **provides
      aggregate "Payment", &body
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

  def registry_with_payments(provides: full_row, operations: %w[Succeeded Failed], body: PAYMENT_AGGREGATE_BODY)
    registry = Hecks::Runtime::Registry.new
    Hecks.with_registry(registry) do
      MemoryPorts.load!
      payments_chapter(provides, body)
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
      .to raise_error(Hecks::Bluebook::DSL::Malformed, /payments needs initiate, succeeded, failed and may add holds_seat/)
  end

  it "refuses an initiate verb that names no command the chapter declares" do
    expect { registry_with_payments(provides: full_row.merge(initiate: "Payment.Begin")) }
      .to raise_error(Hecks::Bluebook::DSL::Malformed, /Payment\.Begin/)
  end

  context "with an optional holds_seat mark" do
    let(:marked_row) { full_row.merge(holds_seat: "Payment.holds_seat") }

    it "exports the states of the lifecycle mark it names" do
      exported = Hecks::Projector::Exporter.payments(
        registry_with_payments(provides: marked_row, body: MARKED_PAYMENT_BODY), "Payments"
      )

      expect(exported).to eq(PAYMENTS_EXPORT.merge(holds_seat: %w[pending paid disputed]))
    end

    it "leaves the export byte-identical to today when the row is not declared" do
      exported = Hecks::Projector::Exporter.payments(registry_with_payments(body: MARKED_PAYMENT_BODY), "Payments")

      expect(exported).to eq(PAYMENTS_EXPORT)
    end

    it "refuses a mark the aggregate's lifecycle does not declare" do
      expect { registry_with_payments(provides: full_row.merge(holds_seat: "Payment.refunded"), body: MARKED_PAYMENT_BODY) }
        .to raise_error(Hecks::Bluebook::DSL::Malformed, /Payment\.refunded.*no lifecycle mark/)
    end

    it "refuses a mark on an aggregate that has no lifecycle" do
      expect { registry_with_payments(provides: marked_row) }
        .to raise_error(Hecks::Bluebook::DSL::Malformed, /Payment\.holds_seat.*no lifecycle mark/)
    end
  end
end
