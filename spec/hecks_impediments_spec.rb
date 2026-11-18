require "spec_helper"
require "tmpdir"
require "hecks/hecks/adapters/dispatching"
require_relative "support/impediment_looks"

# The impediment view reads the tap against the StallKind rows: every source still open past its
# row's minutes, filed or not, oldest first, with its age, owner and help, and gone once the
# row's closing, ending or settling line comes.
RSpec.describe "StallWatch impediments" do
  include_context "with a stall watch tap"
  include ImpedimentLooks

  it "lists every standing source once, the oldest first" do
    write_sources(ImpedimentLooks::STANDING)
    expect(kinds).to eq(%w[codebase-check-failed agent-run-blocked held-lock agent-run-failed])
  end

  it "gives an impediment its source record, age, owner and help", :aggregate_failures do
    write_sources(ImpedimentLooks::STANDING)

    expect(row_of("held-lock")).to include(subject: "hold-1", waited: 15, fixer: "orchestrator", filed: "", count: 1)
    expect(row_of("held-lock")[:detail]).to include("send_train.status")
  end

  it "folds the run findings of a row that folds into one, with how many it stands for" do
    write_sources(ImpedimentLooks::STANDING)
    expect(row_of("codebase-check-failed")).to include(subject: "gate-quick-rubocop", waited: 30, count: 2)
  end

  it "counts only the run findings whose work item is undone" do
    write_sources(ImpedimentLooks::STANDING + [["WorkFinished", "run-77", 1, "Tickets::Work"]])
    expect(row_of("codebase-check-failed")).to include(count: 1)
  end

  ImpedimentLooks::GONE.each do |name, line|
    it "leaves #{name} out once it is gone" do
      write_sources(ImpedimentLooks::STANDING)
      before = kinds
      write_sources(ImpedimentLooks::STANDING + [line])

      expect(before.size - kinds.size).to eq(1)
    end
  end
end
