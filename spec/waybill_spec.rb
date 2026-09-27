require "spec_helper"

# Pins a saga dispatching into a nested entity's own command (qa/stress_domains/waybill).
# Saga dispatch qualifies against its home domain; entity-owned dispatch must resolve its receiver.
RSpec.describe "Waybill" do
  WAYBILL_ROOT = File.join(InMemoryDomain::ROOT, "qa/stress_domains/waybill/bluebook").freeze

  def boot_waybill
    registry = Hecks::Runtime::Registry.new

    Hecks.with_registry(registry) do
      Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
      Kernel.load(InMemoryDomain::EXTRACTION_PORT)
      Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
      Kernel.load(InMemoryDomain::PRISM_ADAPTER)
      Kernel.load(File.join(WAYBILL_ROOT, "waybill.bluebook"))

      Hecks.hecksagon "Waybill" do
        uses_framework "Governance"

        Waybill::Consignment.persisted_by("Memory")
        Waybill::Manifest.persisted_by("Memory")
      end
      sibling_governance!
    end

    registry.verify!
    runtime = Hecks::Runtime::Loader.bind_runtime(Hecks::Runtime::Dispatcher.new(registry))
    [runtime, registry]
  end

  let(:booted) { boot_waybill }
  let(:runtime) { booted.first }
  let(:registry) { booted.last }

  # Manifest.AddSlot never names the optional Slot.item, so the appended Slot must still carry a
  # nil :item key, as Rust's to_json does. Dispatched directly: through the saga, Fill would create
  # the key and hide the gap.
  it "gives a freshly appended Slot a key for its own optional item attribute, unset" do
    runtime
    Waybill::Manifest.open!(reference: { value: "M1" })
    Waybill::Manifest.find("M1").add_slot!(number: { value: 1 })

    slot = Waybill::Manifest.find("M1")[:slots].first
    expect(slot.key?(:item)).to be(true)
    expect(slot[:item]).to be_nil
  end

  it "opens a manifest and reserves a slot through the saga's own aggregate-level dispatches — those work" do
    runtime
    Waybill::Consignment.request!(reference: { value: "C1" }, number: { value: 1 }, item: { text: "widget" })

    manifest = Waybill::Manifest.find("C1")
    expect(manifest[:slots].map { |slot| slot[:number][:value] }).to eq([1])

    delivered = registry.saga_log.select { |entry| entry[:dispatch] }.to_h { |entry| [entry[:dispatch], entry[:delivered]] }
    expect(delivered["Manifest.Open"]).to be(true)
    expect(delivered["Manifest.AddSlot"]).to be(true)
  end

  # Manifest::Slot.Fill, an entity command, delivers and the slot holds the item afterward.
  it "delivers Manifest::Slot.Fill — the saga's own entity-command dispatch works" do
    runtime
    Waybill::Consignment.request!(reference: { value: "C1" }, number: { value: 1 }, item: { text: "widget" })

    fill_attempt = registry.saga_log.find { |entry| entry[:dispatch] == "Manifest::Slot.Fill" }
    expect(fill_attempt).not_to be_nil
    expect(fill_attempt[:delivered]).to be(true)

    manifest = Waybill::Manifest.find("C1")
    expect(manifest[:slots].first[:item][:text]).to eq("widget")
  end

  # Leg 3 delivering lets the saga reach ConsignmentShipped without running the :refused leg.
  it "ships the consignment — the saga's happy path (ConsignmentShipped) is reachable" do
    runtime
    Waybill::Consignment.request!(reference: { value: "C1" }, number: { value: 1 }, item: { text: "widget" })

    expect(Waybill::Consignment.find("C1")[:status]).to eq("shipped")

    ship = registry.saga_log.find { |entry| entry[:dispatch] == "Consignment.Ship" }
    expect(ship[:delivered]).to be(true)
    expect(registry.saga_log.none? { |entry| entry[:dispatch] == "Consignment.Cancel" }).to be(true)
  end
end
