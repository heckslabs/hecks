require "spec_helper"
require "tmpdir"
require "hecks/hecks/adapters/dispatching"
require_relative "support/shared_file_looks"
require_relative "support/help_wanted_looks"

# A call for help with a pair of branches that share files stands while the pair stands at the
# same tips, and a look relieves it once either tip moves: one call per pair until a branch changes.
RSpec.describe "HelpWanted for branches that share files" do
  include_context "with open branches that share a file"
  include HelpWantedLooks

  let(:key) { "stall-branches-share-files-one.two-aaa1111-bbb2222" }

  before do
    write_sources(started)
    raise_help(key)
  end

  it "takes a call under the pair's key" do
    expect(field(:status, "help-#{key}")).to eq("open")
  end

  it "keeps the call while the pair stands at the same tips" do
    expect(relieved).to be_empty
  end

  it "relieves the call once either tip moves" do
    tips["two"] = "ddd4444"
    expect(relieved).to eq(["help-#{key}"])
  end

  it "relieves the call once either work item is finished" do
    append("WorkFinished", "two", "Tickets::Work", 0)
    expect(relieved).to eq(["help-#{key}"])
  end
end
