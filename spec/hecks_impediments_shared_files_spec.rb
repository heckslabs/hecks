require "spec_helper"
require "tmpdir"
require "hecks/hecks/adapters/dispatching"
require_relative "support/shared_file_looks"

# The impediment view computes one entry per pair of open branches that changed the same files
# against main, names only. A branch is open while its work item's latest line is its start.
RSpec.describe "StallWatch impediments for branches that share files" do
  include_context "with open branches that share a file"

  it "lists the pair that shares a file once, with the file's name", :aggregate_failures do
    write_sources(started)

    expect(kinds).to eq(%w[branches-share-files])
    expect(pair).to include(subject: "one+two", waited: 10, fixer: "orchestrator", filed: "", count: 1)
    expect(pair[:detail]).to include("both change lib/b.rb against main")
  end

  it "lists no pair when no file is shared" do
    files["two"] = %w[lib/c.rb]
    write_sources(started)
    expect(kinds).to be_empty
  end

  it "leaves out a branch whose work item is finished" do
    write_sources(started + [["WorkFinished", "two", 1, "Tickets::Work"]])
    expect(kinds).to be_empty
  end

  it "keeps a branch whose work item was yielded and started again" do
    write_sources(started + [["WorkYielded", "two", 5, "Tickets::Work"], ["WorkStarted", "two", 1, "Tickets::Work"]])
    expect(pair).to include(subject: "one+two")
  end
end
