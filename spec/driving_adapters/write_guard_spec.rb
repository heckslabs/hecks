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
  let(:main_rows) do
    [["store Tickets", "Memory", "root"], ["store Tickets::Work", "SqliteAt /x/tickets.db", "hecksagon"],
     ["store Hecks", "Memory", "root"], ["store Hecks::Landing", "SqliteAt /x/agent_run.db", "hecksagon"]]
  end
  let(:stores) { ->(dir) { dir == main ? main_rows : [["store Tickets", "Memory", "root"]] } }

  def verdict(aggregate, dir: worktree, env: {})
    described_class.verdict(dir, "Tickets", aggregate: aggregate, stores: stores, env: env)
  end

  before do
    FileUtils.mkdir_p([File.join(main, ".git"), File.join(main, "lib/hecks/hecks"), worktree])
    File.write(File.join(main, "lib/hecks/hecks/hecks.local.hecksagon"),
               %(Tickets::Work.persisted_by("SqlitePersistence")\n))
    File.write(File.join(worktree, ".git"), "gitdir: #{main}/.git/worktrees/w\n")
  end

  it "forwards an aggregate whose main checkout store is off Memory although its bluebook reads Memory" do
    expect(verdict("Work").forward).to eq(main)
  end

  it "lets an aggregate through that the main checkout also keeps in Memory" do
    expect(verdict("Unbound")).to be_allowed
  end

  it "lets the main checkout write" do
    expect(verdict("Work", dir: main)).to be_allowed
  end

  it "reads a bluebook-level store when the aggregate has none of its own" do
    rows = [["store Tickets", "SqliteAt /x/t.db", "world"]]
    guard = described_class.verdict(worktree, "Tickets", aggregate: "Any", stores: ->(dir) { dir == main ? rows : [] })

    expect(guard.forward).to eq(main)
  end

  it "refuses instead of forwarding when HECKS_NO_FORWARD is set, naming the main checkout" do
    expect(verdict("Work", env: { "HECKS_NO_FORWARD" => "1" }).refusal).to include("Tickets::Work", main)
  end

  it "refuses a run that was already forwarded, so a forward can never loop" do
    expect(verdict("Work", env: { "HECKS_FORWARDED" => "1" }).forward).to be_nil
  end

  it "keeps `refusal` answering the message for callers that only refuse" do
    expect(described_class.refusal(worktree, "Tickets", aggregate: "Work", stores: stores)).to include("refused: Tickets::Work")
  end

  it "keeps `refusal` nil for a Memory aggregate" do
    expect(described_class.refusal(worktree, "Tickets", aggregate: "Unbound", stores: stores)).to be_nil
  end
end
