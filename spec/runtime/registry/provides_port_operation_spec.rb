require "spec_helper"

# A `provides` verb may name a hecksagon port operation
# ("Aggregate.Port.Operation"), for a capability whose contract kind is
# `:port_operation`. The hecksagon attaches after the chapter is built, so
# the chapter only checks the spelling and `Registry#verify!` checks the
# operation exists. No real capability uses this kind yet, so the specs stub
# one into the contract table.
RSpec.describe "a provides verb naming a port operation" do
  before do
    stub_const("Hecks::Bluebook::Capabilities::CONTRACTS",
               { "settlement" => { settled: :port_operation }.freeze }.freeze)
  end

  def probe_chapter(verb)
    Hecks.bluebook "Probe" do
      vision "probe"
      supporting
      provides "settlement", settled: verb
      aggregate "Payment" do
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
      [InMemoryDomain::PERSISTENCE_PORT, InMemoryDomain::EXTRACTION_PORT,
       InMemoryDomain::MEMORY_ADAPTER, InMemoryDomain::PRISM_ADAPTER].each { |path| Kernel.load(path) }
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
