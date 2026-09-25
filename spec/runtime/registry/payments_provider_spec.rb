require "spec_helper"

# rust/host's checkout and webhook routes read ir.json's `payments` key
# instead of naming Payments::Payment verbs. That key is only as
# trustworthy as the `provides "payments"` row behind it, so the row is held
# to its contract (`initiate` names a command; the two verdicts name port
# operations the hecksagon declares) and the exporter answers nothing for a
# domain that attaches no such chapter.
RSpec.describe "payments capability" do
  let(:full_row) do
    {
      initiate:  "Payment.Initiate",
      succeeded: "Payment.PaymentGateway.Succeeded",
      failed:    "Payment.PaymentGateway.Failed"
    }
  end

  def payments_chapter(provides)
    Hecks.bluebook "Payments" do
      vision "probe"
      supporting
      provides "payments", **provides
      aggregate "Payment" do
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
    end
  end

  def payments_hecksagon(operations)
    Hecks.hecksagon("Payments") do
      Payments::Payment.persisted_by("Memory")
      Payments::Payment.port "PaymentGateway" do
        operations.each do |name|
          operation name do
            attribute :note, String
            emits "Payment#{name}"
          end
        end
      end
    end
  end

  def registry_with_payments(provides: full_row, operations: %w[Succeeded Failed])
    registry = Hecks::Runtime::Registry.new
    Hecks.with_registry(registry) do
      [InMemoryDomain::PERSISTENCE_PORT, InMemoryDomain::EXTRACTION_PORT,
       InMemoryDomain::MEMORY_ADAPTER, InMemoryDomain::PRISM_ADAPTER].each { |path| Kernel.load(path) }
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
    registry = registry_with_payments

    expect(Hecks::Projector::Exporter.payments(registry, "Payments")).to eq(
      provider:  "Payments",
      initiate:  "Payments::Payment.Initiate",
      succeeded: "Payments::Payment.PaymentGateway.Succeeded",
      failed:    "Payments::Payment.PaymentGateway.Failed",
      aggregate: "Payments::Payment"
    )
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
