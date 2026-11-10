require "spec_helper"
require "hecks/hecks/adapters/claude_cleaning"
require "tmpdir"
require "fileutils"
require "json"

# A stand-in `claude` that lists seven sessions and logs each call, a transcript per session, and
# a stand-in AgentRun reader, shared by the examples below.
module CleaningStandIn
  LISTING = [
    { id: "own1", sessionId: "own1-full", name: "owner blocked", state: "blocked" },
    { id: "own2", sessionId: "own2-full", name: "owner stopped", state: "stopped" },
    { id: "free", sessionId: "free-full", name: "no run", state: "done" },
    { id: "halt", sessionId: "halt-full", name: "run stopped", state: "done" },
    { id: "work", sessionId: "work-full", name: "still started", state: "done" },
    { id: "spok", sessionId: "spok-full", name: "spoken to", state: "done" },
    { id: "fini", sessionId: "fini-full", name: "finished", state: "done" }
  ].freeze

  SESSIONS = { "own2-full" => "r-own2", "halt-full" => "r-halt", "work-full" => "r-work",
               "spok-full" => "r-spok", "fini-full" => "r-fini" }.freeze

  RUNS = { "r-own2" => %w[started], "r-halt" => %w[finished stopped], "r-work" => %w[started],
           "r-spok" => %w[finished done], "r-fini" => %w[finished done] }.freeze

  SCRIPT = <<~SH.freeze
    #!/bin/sh
    d=$(dirname "$0"); echo "$*" >> "$d/calls.log"
    case "$1" in
      agents) cat "$d/sessions.json" ;;
    esac
  SH

  def ledger
    runs = RUNS.transform_values { |(status, condition)| { status: status, condition: condition.to_s } }
    instance_double(Hecks::Adapters::Dispatching::WorkItems, run_sessions: SESSIONS, runs: runs)
  end

  def stand_in(scratch)
    File.write(File.join(scratch, "sessions.json"), JSON.generate(LISTING))
    File.write(File.join(scratch, "claude"), SCRIPT)
    File.chmod(0o755, File.join(scratch, "claude"))
    LISTING.each { |entry| transcript(scratch, entry[:sessionId], entry[:id] == "spok" ? 2 : 1) }
  end

  def transcript(scratch, full, people)
    dir = FileUtils.mkdir_p(File.join(scratch, "projects", "p")).first
    line = JSON.generate(type: "user", message: { content: "a brief" })
    File.write(File.join(dir, "#{full}.jsonl"), "#{([line] * people).join("\n")}\n")
  end

  def removals = File.readlines(File.join(scratch, "calls.log"), chomp: true).grep(/\Arm /)

  def kept_line(id) = adapter.removable[:text].lines.find { |line| line.start_with?(id) }.to_s
end

# The `ClaudeCleaning` adapter: a session is removed only when a dispatched run holds it, that run
# finished `done`, the listing says `done` and no person spoke in it.
RSpec.describe Hecks::Adapters::ClaudeCleaning do
  include CleaningStandIn

  let(:scratch) { File.realpath(Dir.mktmpdir("cleaning-claude")) }
  let(:settings) { { command: File.join(scratch, "claude"), projects: File.join(scratch, "projects") } }
  let(:adapter) { described_class.new(settings: settings) }

  before do
    stand_in(scratch)
    allow(Hecks::Adapters::Dispatching::WorkItems).to receive(:new).and_return(ledger)
  end

  after { FileUtils.rm_rf(scratch) }

  it "removes only the session of a dispatched run that finished done" do
    adapter.clean(confirm: true)
    expect(removals).to eq(["rm fini"])
  end

  {
    "own1" => "no dispatched run holds it",
    "free" => "no dispatched run holds it",
    "halt" => "its run r-halt is finished stopped, not finished done",
    "own2" => "its run r-own2 is started, not finished done",
    "work" => "its run r-work is started, not finished done",
    "spok" => "a person spoke in it"
  }.each do |id, reason|
    it "keeps session #{id}: #{reason}" do
      expect(kept_line(id)).to include("kept: #{reason}")
    end
  end
end
