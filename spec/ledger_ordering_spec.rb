require "spec_helper"

# Pins which refusal wins, entity addressing or argument invariant (ADR 0037); see
# qa/stress_domains/ledger_ordering/NOTES.md.
RSpec.describe "LedgerOrdering" do
  LEDGER_ORDERING_ROOT = File.join(InMemoryDomain::ROOT, "qa/stress_domains/ledger_ordering/bluebook").freeze

  def boot_ledger_ordering
    registry = Hecks::Runtime::Registry.new

    Hecks.with_registry(registry) do
      Kernel.load(InMemoryDomain::PERSISTENCE_PORT)
      Kernel.load(InMemoryDomain::EXTRACTION_PORT)
      Kernel.load(InMemoryDomain::MEMORY_ADAPTER)
      Kernel.load(InMemoryDomain::PRISM_ADAPTER)
      Kernel.load(File.join(LEDGER_ORDERING_ROOT, "ledger_ordering.bluebook"))

      Hecks.hecksagon "LedgerOrdering" do
        attaches "Governance"

        LedgerOrdering::Folder.persisted_by("Memory")
      end
      sibling_governance!
    end

    registry.verify!
    Hecks::Runtime::Loader.bind_runtime(Hecks::Runtime::Dispatcher.new(registry))
  end

  let(:runtime) { boot_ledger_ordering }

  it "opens a folder and adds a slip" do
    runtime
    LedgerOrdering::Folder.open!(reference: { value: "F1" })
    folder = LedgerOrdering::Folder.find("F1").add_slip!(reference: { value: "S1" }, amount: { value: 10 })

    expect(folder[:slips].map { |slip| slip[:reference][:value] }).to eq(["S1"])
  end

  # Both refusals apply at once: the slip was never added and `amount.value` fails
  # its invariant. Ruby constructs arguments before looking up the entity.
  it "raises the argument's own InvariantViolation before checking whether the addressed slip exists" do
    runtime
    LedgerOrdering::Folder.open!(reference: { value: "F1" })

    expect do
      runtime.dispatch_flat("LedgerOrdering::Folder.Slip.Amend",
                            to: { aggregate: "F1", entity: "NOPE" }, amount: { value: -1 })
    end.to raise_error(Hecks::Runtime::InvariantViolation, /positive/)
  end
end
