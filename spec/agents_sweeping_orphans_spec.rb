require "spec_helper"
require_relative "support/sweeping_fixtures"

# The launchers left running with no parent and the rehearsal pushes older than a day: a stand-in
# process table, killer, temp directory and working-directory reader, so no real process is listed
# or stopped.
RSpec.describe Hecks::Adapters::Sweeping::Orphans do
  include_context "with a sweep fixture"

  let(:day) { 86_400 }
  let(:late) { 2_000 }
  let(:table) { instance_double(Hecks::Adapters::Sweeping::ProcessTable) }
  let(:other) { Dir.mktmpdir("hecks-other-tmp") }

  before { traced_log }

  after { FileUtils.remove_entry(other) }

  def entry(pid, ppid, age, command) = Hecks::Adapters::Sweeping::ProcessTable::Entry.new(pid, ppid, age, 1, command)

  def below(all, pid) = all.select { |e| e.ppid == pid }.flat_map { |e| [e] + below(all, e.pid) }

  def alive(entries) = entries.reject { |e| killed.include?(e.pid) }

  def stub_table(entries, cwds)
    allow(table).to receive(:entries) { alive(entries) }
    allow(table).to receive_messages(working_directories: cwds)
    allow(table).to receive(:below) { |pid, all| below(all, pid) }
  end

  def orphans(entries, tmp: dir, cwds: [], killer: ->(pid) { killed << pid })
    stub_table(entries, cwds)
    described_class.new(table: table, killer: killer, tmp: tmp, pause: -> {})
  end

  it "lists a launcher older than half an hour whose parent is init" do
    found = orphans([entry(900, 1, late, "ruby exe/hecks tickets Work.undone")]).lines

    expect(found.join).to include("leftover  pid=900")
  end

  it "keeps a launcher whose parent is alive and a young one", :aggregate_failures do
    kept = [entry(10, 1, 9000, "zsh"), entry(901, 10, 9000, "exe/hecks x"), entry(902, 1, 1500, "exe/hecks x")]

    expect(orphans(kept).lines).to eq([])
  end

  it "keeps a server, a tick, a gate, a spec run and a wait", :aggregate_failures do
    commands = ["ruby exe/hecks pipeline_board PipelineBoard.serve!", "exe/hecks quality_control sweep.tick",
                "exe/hecks gate_run.gate! stage=quick --wait", "ruby exe/hecks Operation.follow wait=600",
                "exe/hecks test_suite_run.run_impacted_specs! --wait", "exe/hecks Operation.run! verb.value=x"]
    kept = commands.each_with_index.map { |command, index| entry(910 + index, 1, 9000, command) }

    expect(orphans(kept).lines).to eq([])
  end

  it "ignores a command that only names the launcher", :aggregate_failures do
    texts = ["vim exe/hecks x", "grep x exe/hecks ", "claude -p run exe/hecks tickets Work.undone"]
    named = texts.each_with_index.map { |command, index| entry(920 + index, 1, 9000, command) }

    expect(orphans(named + [entry(904, 1, 9000, "ruby -I lib -e require 'hecks/tools/mcp'")]).lines).to eq([])
  end

  it "finds a launcher run directly, under ruby, or under bundle exec ruby" do
    commands = ["./exe/hecks x", "/usr/bin/ruby -I lib exe/hecks x", "bundle exec ruby exe/hecks x"]
    found = commands.each_with_index.map { |command, index| entry(930 + index, 1, late, command) }

    expect(orphans(found).lines.length).to eq(3)
  end

  it "stops a launcher whose parent is gone and what runs below it, but not a session or a build", :aggregate_failures do
    tree = [entry(905, 777, late, "exe/hecks x"), entry(906, 905, 5, "git fetch"),
            entry(907, 905, 5, "claude --bg"), entry(908, 907, 5, "git status"), entry(909, 905, 5, "cargo build")]
    orphans(tree).reap

    expect(killed).to eq([905, 906])
  end

  it "leaves a process whose pid was reused since the listing", :aggregate_failures do
    listed = [entry(940, 1, late, "exe/hecks x")]
    stub_table(listed, [])
    allow(table).to receive(:entries).and_return(listed, [entry(940, 1, 3, "vim notes.txt")])
    lines = described_class.new(table: table, killer: ->(pid) { killed << pid }, tmp: dir, pause: -> {}).reap

    expect([killed, lines.join]).to match([[], /left alone, the pid was reused/])
  end

  it "goes on past a process it may not signal, and says so", :aggregate_failures do
    tree = [entry(950, 1, late, "exe/hecks x"), entry(951, 1, late, "exe/hecks y")]
    refuse = ->(pid) { pid == 950 ? raise(Errno::EPERM) : killed << pid }
    lines = orphans(tree, killer: refuse).reap

    expect([killed, lines.join]).to match([[951], /not stopped, permission denied.*stopped  pid=951/m])
  end

  it "reports a process still running after the stop, not stopped" do
    stub_table([], [])
    allow(table).to receive(:entries).and_return([entry(960, 1, late, "exe/hecks x")])
    lines = described_class.new(table: table, killer: ->(pid) { killed << pid }, tmp: dir, pause: -> {}).reap

    expect(lines.join).to include("still running  pid=960")
  end

  it "stops a rehearsal push older than a day and the git push that started it", :aggregate_failures do
    path = "/tmp/hecks-isolated-push2026-x/origin.git"
    entries = [entry(20, 1, day + 5, "git -c hecks.trainCarry=ab push origin ab:refs/heads/main"),
               entry(21, 20, day + 5, "git-receive-pack #{path}"), entry(22, 20, day + 5, "/bin/sh #{path}/hooks/pre-push")]
    orphans(entries).reap

    expect(killed).to eq([21, 22, 20])
  end

  it "does not take a git command that is not a push for the rehearsal's push" do
    path = "/tmp/hecks-isolated-push2026-x/origin.git"
    orphans([entry(30, 1, day + 5, "git status"), entry(31, 30, day + 5, "git-receive-pack #{path}")]).reap

    expect(killed).to eq([31])
  end

  it "keeps a rehearsal push younger than a day" do
    expect(orphans([entry(23, 1, 600, "git-receive-pack /tmp/hecks-isolated-push1/origin.git")]).lines).to eq([])
  end

  def make_dirs(*names, aged:)
    names.each { |name| Dir.mkdir(File.join(dir, name)) }
    old = Time.now - (2 * day)
    aged.each { |name| File.utime(old, old, File.join(dir, name)) }
  end

  def directories_after_reap(**options)
    make_dirs("hecks-isolated-push-old", "hecks-isolated-push-young", "other", aged: ["hecks-isolated-push-old"])
    orphans([], **options).reap
    Dir.children(dir).sort
  end

  it "deletes only rehearsal directories older than a day" do
    expect(directories_after_reap).to eq(%w[daemon.log hecks-isolated-push-young other])
  end

  def age_directory(path)
    old = Time.now - (2 * day)
    File.utime(old, old, path)
  end

  it "keeps an old rehearsal directory when something inside it changed lately" do
    busy = File.join(dir, "hecks-isolated-push-busy")
    FileUtils.mkdir_p(busy)
    File.write(File.join(busy, "work"), "x")
    age_directory(busy)

    expect(orphans([]).reap && Dir.children(dir)).to include("hecks-isolated-push-busy")
  end

  it "keeps an old rehearsal directory a process has as its working directory" do
    in_use = ["#{File.realpath(dir)}/hecks-isolated-push-old/work"]

    expect(directories_after_reap(cwds: in_use)).to include("hecks-isolated-push-old")
  end

  it "keeps every old rehearsal directory when the working directories cannot be read" do
    expect(directories_after_reap(cwds: nil)).to include("hecks-isolated-push-old")
  end

  it "searches every temp directory it is given" do
    Dir.mkdir(File.join(other, "hecks-isolated-push-far"))
    age_directory(File.join(other, "hecks-isolated-push-far"))

    expect(orphans([], tmp: [dir, other]).reap && Dir.children(other)).to eq([])
  end

  it "adds the leftovers to a sweep's report and to its preview", :aggregate_failures do
    shell = fake_shell
    adapter(shell).sweep(removed: "aaaaaaaa")

    expect(adapter(shell).leftovers(removed: "aaaaaaaa")[:text]).to start_with("footprint")
  end
end
