require "spec_helper"

# Pins which refusal wins, entity addressing or argument invariant (ADR 0037); see
# qa/stress_domains/ledger_ordering/NOTES.md.
RSpec.describe "LedgerOrdering" do
  LEDGER_ORDERING_ROOT = File.join(InMemoryDomain::ROOT, "qa/stress_domains/ledger_ordering/bluebook").freeze

  def declare_ledger_ordering_hecksagon
    Hecks.hecksagon "LedgerOrdering" do
      attaches "Governance"

      LedgerOrdering::Folder.persisted_by("Memory")
    end
  end

  def load_ledger_ordering
    [InMemoryDomain::PERSISTENCE_PORT, InMemoryDomain::EXTRACTION_PORT, InMemoryDomain::MEMORY_ADAPTER,
     InMemoryDomain::PRISM_ADAPTER, File.join(LEDGER_ORDERING_ROOT, "ledger_ordering.bluebook")].each { |file| Kernel.load(file) }
    declare_ledger_ordering_hecksagon
    sibling_governance!
  end

  def boot_ledger_ordering
    registry = Hecks::Runtime::Registry.new

    Hecks.with_registry(registry) { load_ledger_ordering }

    registry.verify!
    Hecks::Runtime::Loader.bind_runtime(Hecks::Runtime::Dispatcher.new(registry))
  end

  let!(:runtime) { boot_ledger_ordering }

  it "opens a folder and adds a slip" do
    LedgerOrdering::Folder.open!(reference: { value: "F1" })
    folder = LedgerOrdering::Folder.find("F1").add_slip!(reference: { value: "S1" }, amount: { value: 10 })

    expect(folder[:slips].map { |slip| slip[:reference][:value] }).to eq(["S1"])
  end

  # Both refusals apply at once: the slip was never added and `amount.value` fails
  # its invariant. Ruby constructs arguments before looking up the entity.
  it "raises the argument's own InvariantViolation before checking whether the addressed slip exists" do
    LedgerOrdering::Folder.open!(reference: { value: "F1" })

    expect do
      runtime.dispatch_flat("LedgerOrdering::Folder.Slip.Amend",
                            to: { aggregate: "F1", entity: "NOPE" }, amount: { value: -1 })
    end.to raise_error(Hecks::Runtime::InvariantViolation, /positive/)
  end
end
