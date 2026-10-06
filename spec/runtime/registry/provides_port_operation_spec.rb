require "spec_helper"
require_relative "../../support/memory_ports"

# A `provides` verb of kind `:port_operation` is spelled at build time and checked by verify!,
# since the hecksagon attaches later. No real capability uses the kind, so it is stubbed.
RSpec.describe "a provides verb naming a port operation" do
  PROBE_PAYMENT_BODY = proc do
    identified_by :reference
    attribute :reference, Reference
    value_object "Reference" do
      attribute :value, String
    end
    command "Open" do
      goal "open"
      attribute :reference, Reference
      sets :reference
    end
  end

  before do
    stub_const("Hecks::Bluebook::Capabilities::CONTRACTS",
               { "settlement" => { settled: :port_operation }.freeze }.freeze)
  end

  def probe_chapter(verb)
    Hecks.bluebook "Probe" do
      vision "probe"
      supporting
      provides "settlement", settled: verb
      aggregate "Payment", &PROBE_PAYMENT_BODY
    end
  end

  def probe_hecksagon(port_operation)
    Hecks.hecksagon("Probe") do
      Probe::Payment.persisted_by("Memory")
      Probe::Payment.port "Gateway" do
        operation port_operation do
          attribute :note, String
          emits "PaymentSettled"
        end
      end
    end
  end

  def registry_providing(verb, port_operation: "Settled")
    registry = Hecks::Runtime::Registry.new
    Hecks.with_registry(registry) do
      MemoryPorts.load!
      probe_chapter(verb)
      probe_hecksagon(port_operation)
    end
    registry
  end

  it "boots when the hecksagon declares the named port operation" do
    expect { registry_providing("Payment.Gateway.Settled").verify! }.not_to raise_error
  end

  it "refuses at verify! when the port has no such operation" do
    registry = registry_providing("Payment.Gateway.Settled", port_operation: "Declined")

    expect { registry.verify! }
      .to raise_error(Hecks::Runtime::WiringError, /Probe provides "settlement" settled.*no such port operation/)
  end

  it "refuses at verify! when the aggregate has no such port" do
    registry = registry_providing("Payment.Elsewhere.Settled")

    expect { registry.verify! }.to raise_error(Hecks::Runtime::WiringError, /no such port operation/)
  end

  it "refuses a verb that is not spelled Aggregate.Port.Operation" do
    expect { registry_providing("Settled") }
      .to raise_error(Hecks::Bluebook::DSL::Malformed, /Aggregate\.Port\.Operation/)
  end

  it "refuses a verb whose aggregate the chapter does not declare" do
    expect { registry_providing("Nowhere.Gateway.Settled") }
      .to raise_error(Hecks::Bluebook::DSL::Malformed, /Nowhere\.Gateway\.Settled/)
  end
end
