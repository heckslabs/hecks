require "spec_helper"
require "hecks/hecks/adapters/stall_watching"
require_relative "support/branch_repository"

# The impediment view's read of the machine: the named work items that are local branches, each
# with its tip, the tip's commit time and the file names it changes against main.
RSpec.describe Hecks::Adapters::StallWatching::OpenBranches do
  include BranchRepository

  let(:repo) { Dir.mktmpdir("open-branches") }
  let(:read) { described_class.new(repo).call(%w[one two gone]) }

  before do
    start_repository
    branch_editing("one", "lib/a.rb", "lib/b.rb")
    branch_editing("two", "lib/b.rb")
    branch_editing("unasked", "lib/b.rb")
  end

  after { FileUtils.remove_entry(repo) }

  it "answers only the named work items that are local branches" do
    expect(read.map { |branch| branch[:branch] }).to eq(%w[one two])
  end

  it "names the files each branch changes against main" do
    expect(read.first[:files]).to eq(%w[lib/a.rb lib/b.rb])
  end

  it "gives each branch its short tip" do
    expect(read.first[:tip]).to eq(git("rev-parse", "--short", "one").out.strip)
  end

  it "gives the tip's commit time in UTC" do
    expect(read.first[:at]).to match(/\A\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ\z/)
  end

  it "answers none where git cannot list branches" do
    Dir.mktmpdir("no-repository") { |dir| expect(described_class.new(dir).call(%w[one])).to eq([]) }
  end
end
