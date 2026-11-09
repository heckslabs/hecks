require "spec_helper"
require_relative "support/sweeping_fixtures"

# The launchers left running with no parent and the rehearsal pushes older than a day: a stand-in
# process table and a stand-in killer, so no real process is listed or stopped.
RSpec.describe Hecks::Adapters::Sweeping::Orphans do
  include_context "with a sweep fixture"

  let(:day) { 86_400 }
  let(:table) { instance_double(Hecks::Adapters::Sweeping::ProcessTable) }

  before { traced_log }

  def entry(pid, ppid, age, command) = Hecks::Adapters::Sweeping::ProcessTable::Entry.new(pid, ppid, age, 1, command)

  def orphans(entries, tmp: dir)
    allow(table).to receive_messages(entries: entries)
    allow(table).to receive(:below) { |pid, all| all.select { |e| e.ppid == pid } }
    Hecks::Adapters::Sweeping::Orphans.new(table: table, killer: ->(pid) { killed << pid }, tmp: tmp)
  end

  it "lists a launcher older than ten minutes whose parent is init" do
    found = orphans([entry(900, 1, 700, "ruby exe/hecks tickets Work.undone")]).lines

    expect(found.join).to include("leftover  pid=900")
  end

  it "keeps a launcher whose parent is alive, a young one, and a server", :aggregate_failures do
    kept = [entry(10, 1, 9000, "zsh"), entry(901, 10, 9000, "exe/hecks x"), entry(902, 1, 100, "exe/hecks x"),
            entry(903, 1, 9000, "ruby exe/hecks pipeline_board PipelineBoard.serve!"),
            entry(904, 1, 9000, "ruby -I lib -e require 'hecks/tools/mcp'")]

    expect(orphans(kept).lines).to eq([])
  end

  it "stops a launcher whose parent is gone, and what runs below it", :aggregate_failures do
    orphans([entry(905, 777, 700, "exe/hecks x"), entry(906, 905, 5, "git fetch")]).reap

    expect(killed).to eq([905, 906])
  end

  it "stops a rehearsal push older than a day and the git push that started it", :aggregate_failures do
    path = "/tmp/hecks-isolated-push2026-x/origin.git"
    entries = [entry(20, 1, day + 5, "git -c hecks.trainCarry=ab push origin ab:refs/heads/main"),
               entry(21, 20, day + 5, "git-receive-pack #{path}"), entry(22, 20, day + 5, "/bin/sh #{path}/hooks/pre-push")]
    orphans(entries).reap

    expect(killed).to eq([21, 22, 20])
  end

  it "keeps a rehearsal push younger than a day" do
    expect(orphans([entry(23, 1, 600, "git-receive-pack /tmp/hecks-isolated-push1/origin.git")]).lines).to eq([])
  end

  def make_dirs(*names, aged:)
    names.each { |name| Dir.mkdir(File.join(dir, name)) }
    old = Time.now - (2 * day)
    File.utime(old, old, File.join(dir, aged))
  end

  def directories_after_reap
    make_dirs("hecks-isolated-push-old", "hecks-isolated-push-young", "other", aged: "hecks-isolated-push-old")
    orphans([]).reap
    Dir.children(dir).sort
  end

  it "deletes only rehearsal directories older than a day" do
    expect(directories_after_reap).to eq(%w[daemon.log hecks-isolated-push-young other])
  end

  it "adds the leftovers to a sweep's report and to its preview", :aggregate_failures do
    shell = fake_shell
    adapter(shell).sweep(removed: "aaaaaaaa")

    expect(adapter(shell).leftovers(removed: "aaaaaaaa")[:text]).to start_with("footprint")
  end
end
