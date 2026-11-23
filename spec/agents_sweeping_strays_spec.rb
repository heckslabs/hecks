require "spec_helper"
require "tmpdir"
require "hecks/agents/adapters/sweeping"

# A process bound to no held run and past its time limit: a stuck tick, a resident fork of a
# worktree nobody holds, a mock-up server. Stand-ins for the process table and the killer, so no
# real process is listed or stopped.
RSpec.describe Hecks::Adapters::Sweeping::Orphans do
  let(:table) { instance_double(Hecks::Adapters::Sweeping::ProcessTable) }
  let(:killed) { [] }
  let(:tick) { "ruby -e require \"x/ticking/chain\";Hecks::Adapters::Ticking::Chain.run(ARGV); abc123" }
  let(:resident) { "hecks resident gone-branch (resident/server.rb /r/.claude/worktrees/gone-branch)" }

  def late = 4_000

  def entry(pid, age, command, ppid: 10)
    Hecks::Adapters::Sweeping::ProcessTable::Entry.new(pid, ppid, age, 1, command)
  end

  def stub_table(entries)
    allow(table).to receive_messages(entries: entries, working_directories: [])
    allow(table).to receive(:below) { |pid, all| all.select { |e| e.ppid == pid } }
  end

  def orphans(entries)
    stub_table(entries)
    described_class.new(table: table, killer: ->(pid) { killed << pid }, tmp: [], pause: -> {})
  end

  def stopped(entries, held: [])
    orphans([entry(10, 99_999, "zsh", ppid: 1)] + entries).reap(held: held)
    killed
  end

  it "stops a tick, a resident fork and a mock-up server past the limit", :aggregate_failures do
    shapes = [entry(21, late, tick), entry(22, late, resident), entry(23, late, "ruby mockup/serve.rb 4000")]

    expect(stopped(shapes)).to contain_exactly(21, 22, 23)
  end

  it "keeps one younger than the limit" do
    expect(stopped([entry(21, 600, tick)])).to eq([])
  end

  it "keeps one that names a held branch" do
    expect(stopped([entry(22, late, resident)], held: ["gone-branch"])).to eq([])
  end

  it "keeps the primary checkout's resident" do
    primary = "hecks resident hecks (resident/server.rb /Users/me/Projects/hecks)"

    expect(stopped([entry(24, late, primary)])).to eq([])
  end

  it "keeps the board, the train and a wait on an event, though old and unbound", :aggregate_failures do
    kept = ["exe/hecks pipeline_board PipelineBoard.serve!", "exe/hecks SendTrain.board! --confirm",
            "exe/hecks Operation.follow wait=600"].each_with_index.map { |c, i| entry(30 + i, late, c, ppid: 1) }

    expect(stopped(kept)).to eq([])
  end

  it "keeps an editor, a grep and a tail that only name serve.rb", :aggregate_failures do
    named = ["vim mockup/serve.rb", "grep serve.rb log", "tail -f serve.rb"]

    expect(stopped(named.each_with_index.map { |c, i| entry(40 + i, late, c) })).to eq([])
  end

  it "stops a detached tick by its own pid, leaving what it runs" do
    tick = entry(21, late, "exe/hecks Ticker.tick!", ppid: 1)

    expect(stopped([tick, entry(26, late, "git", ppid: 21)])).to eq([21])
  end

  it "stops only the stray's own pid, never its children" do
    kid = entry(26, late, "git status", ppid: 21)

    expect(stopped([entry(21, late, tick), kid])).to eq([21])
  end

  it "lists a stray in the leftovers without stopping it" do
    expect(orphans([entry(21, late, tick)]).lines.join).to include("stray  pid=21")
  end
end
