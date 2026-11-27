require "spec_helper"
require "hecks/hecks/adapters/stall_watching"
require_relative "support/branch_repository"
require_relative "support/shared_file_looks"

# Two open branches are a pair only on files their unlanded commits change: a commit main holds
# under another hash is landed work and shares nothing.
RSpec.describe "StallWatch impediments for branches that share only landed work" do
  include BranchRepository

  let(:repo) { Dir.mktmpdir("unlanded-files") }
  let(:read) { Hecks::Adapters::StallWatching::OpenBranches.new(repo).call(%w[one two]) }
  let(:files) { read.to_h { |branch| [branch[:branch], branch[:files]] } }

  before do
    start_repository
    branch_editing("one", "lib/landed.rb")
    branch_editing("two", "lib/landed.rb")
    commit_files("lib/elsewhere.rb")
    git("cherry-pick", "one")
  end

  after { FileUtils.remove_entry(repo) }

  it "counts no file for a branch whose only commit main already holds" do
    expect(files).to eq("one" => [], "two" => [])
  end

  it "counts the file a branch's unlanded commit changes" do
    git("checkout", "-q", "one")
    commit_files("lib/pending.rb")
    git("checkout", "-q", "main")
    expect(files).to include("one" => ["lib/pending.rb"])
  end
end

RSpec.describe "StallWatch impediments name the row to read" do
  include_context "with open branches that share a file"

  it "tells the watcher the command that reads its own row" do
    write_sources(started)
    expect(pair[:detail]).to include("StallWatch.impediments run=<your run key> stall=#{pair[:stall]}")
  end
end
