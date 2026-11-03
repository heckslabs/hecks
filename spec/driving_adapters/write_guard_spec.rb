require "spec_helper"
require "tmpdir"
require "fileutils"

RSpec.describe Hecks::Adapters::Driving::WriteGuard do
  around do |example|
    Dir.mktmpdir do |root|
      @root = root
      example.run
    end
  end

  let(:main) { File.join(@root, "main") }
  let(:worktree) { File.join(@root, "worktree") }
  let(:stores) do
    lambda do |dir|
      kind = dir == main ? "SqliteAt /x/tickets.db" : "Memory"
      [["store Tickets", kind, "world"], ["store Hecks", "Memory", "hecksagon"]]
    end
  end

  before do
    FileUtils.mkdir_p([File.join(main, ".git"), File.join(main, "lib/hecks/hecks"), worktree])
    File.write(File.join(main, "lib/hecks/hecks/hecks.local.hecksagon"),
               %(Tickets::Work.persisted_by("SqlitePersistence")\n))
    File.write(File.join(worktree, ".git"), "gitdir: #{main}/.git/worktrees/w\n")
  end

  it "refuses a bluebook whose main checkout stores it off Memory" do
    expect(described_class.refusal(worktree, "Tickets", stores: stores)).to include("refused: Tickets")
  end

  it "lets a Memory bluebook through" do
    expect(described_class.refusal(worktree, "Hecks", stores: stores)).to be_nil
  end

  it "lets the main checkout write" do
    expect(described_class.refusal(main, "Tickets", stores: stores)).to be_nil
  end
end
