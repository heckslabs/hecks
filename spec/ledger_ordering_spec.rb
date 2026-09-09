require "spec_helper"

# qa/stress_domains/ledger_ordering — see its own NOTES.md for why this
# domain exists: an isolated, minimal re-trigger of the ordering question
# ADR 0037's LedgerEntry.Amend finding raised (entity-addressing vs.
# argument-invariant, which one wins). Ruby-only for now — the Rust half
# needs `bin/project_rust qa/stress_domains/ledger_ordering` run first,
# see NOTES.md.
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
        uses_framework "Governance"

        LedgerOrdering::Folder.persisted_by("Memory")
      end
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

  # THE STRESS DISPATCH — the whole reason this domain exists. `to.entity`
  # names a Slip that was never added; `amount.value` fails its own
  # invariant. Both are true at once — which refusal comes back first is
  # the question, and Ruby's own construction-before-lookup order answers
  # it before entity existence is ever asked.
  it "raises the argument's own InvariantViolation before checking whether the addressed slip exists" do
    runtime
    LedgerOrdering::Folder.open!(reference: { value: "F1" })

    expect do
      runtime.dispatch("LedgerOrdering::Folder.Slip.Amend",
                       to: { aggregate: "F1", entity: "NOPE" }, amount: { value: -1 })
    end.to raise_error(Hecks::Runtime::InvariantViolation, /positive/)
  end
end
