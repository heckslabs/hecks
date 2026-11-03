require "spec_helper"
require "tmpdir"

# No spec writes to ~/.claude/hecks-dev. The Hecks domain boots in Memory through
# `boot_hecks_in_memory` whatever local files the checkout keeps, and the SQLite store refuses
# the live directory outright, so a spec that gets around the overlay fails instead of
# filling the owner's ticket ledger.
RSpec.describe LiveLedgerGuard do
  let(:aggregate) { instance_double(Hecks::Bluebook::Aggregate, name: "Work", storage_name: "work", prior_storage_names: []) }

  it "refuses to open a database under the live ledger directory" do
    path = File.join(described_class.dir, "tickets.db")

    expect { Hecks::Adapters::Sqlite.new(aggregate: aggregate, settings: { database: path, domain: "Tickets" }) }
      .to raise_error(described_class::Violation, /live ledger/)
  end

  it "reads a temp directory as outside the live ledger", :aggregate_failures do
    expect(described_class.live?(File.join(Dir.tmpdir, "tickets.db"))).to be(false)
    expect(described_class.live?(File.join(described_class.dir, "agent_run.db"))).to be(true)
  end

  it "opens no SQLite store at all when the Hecks domain boots for a spec" do
    allow(Hecks::Adapters::Sqlite).to receive(:new).and_call_original
    registry = boot_hecks_in_memory.registry
    work = registry.bluebook("Tickets").aggregates.find { |candidate| candidate.name == "Work" }
    registry.repository("Tickets", work)

    expect(Hecks::Adapters::Sqlite).not_to have_received(:new)
  end
end
