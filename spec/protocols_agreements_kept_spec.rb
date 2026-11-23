require "spec_helper"
require_relative "support/protocols_kept_store"

# A working agreement entered by one process is read by the next: the Protocols bluebook is booted
# twice, each boot its own registry, over the store the overlay binds for its kept rows.
RSpec.describe "the crew's working agreements, across processes" do
  let(:root) { Dir.mktmpdir("protocols-store") }
  let(:rows) { Hecks::Adapters::MainIntegration::KeptRows.from_registry(boot_hecks_in_memory.registry) }

  after { FileUtils.remove_entry(root) }

  def enter(reference)
    Protocols::Agreement.propose!(reference: { value: reference }, text: { value: "Done means seen working" },
                                  proposer: { value: "scrum-master" }, affects: { value: "|coder|" },
                                  touches_owner: { value: "no" }, owed: { value: 1 })
    Protocols::Agreement.find(reference).enter!(evidence: { value: "msg-1" })
  end

  it "lists in a second process the agreement the first entered" do
    ProtocolsKeptStore.boot(root, rows)
    enter("WA-1")
    ProtocolsKeptStore.boot(root, rows)
    expect(Protocols::Agreement.accepted.map { |a| a[:reference][:value] }).to eq(["WA-1"])
  end
end
