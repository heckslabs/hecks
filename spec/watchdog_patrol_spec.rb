require "spec_helper"
require_relative "support/watchdog_stand_ins"

# One pass of the watchdog's loop over the declared pinned sessions: a session claude no longer
# works is resumed under its name with its loops re-armed, a working one is left alone, and
# the loop only ever starts things. The shell and the clock are stand-ins, so nothing is resumed.
RSpec.describe "the watchdog resumes the pinned sessions that died" do
  include WatchdogStandIns

  let(:home) { Dir.mktmpdir("watchdog") }
  let(:shell) { WatchdogStandIns::Shell.new(listed: [entry("ORCHESTRATOR", "stopped"), entry("miette", "working")]) }
  let(:now) { [1_000] }
  let(:journal) { File.readlines(File.join(home, "journal.jsonl")).map { |line| JSON.parse(line) } }

  after { FileUtils.rm_rf(home) }

  def pass(roster = roster_of("ORCHESTRATOR", "miette"))
    require "hecks/hecks/adapters/guarding/loop/pass"
    Hecks::Adapters::Guarding::Loop::Pass.new(roster: roster, shell: shell, clock: -> { now.first }, home: home).run
  end

  it "resumes the lead under its name from its own directory" do
    pass
    expect(shell.resumes.map { |call| [call[:argv], call[:chdir]] })
      .to eq([[%w[claude --bg --resume id-ORCHESTRATOR -n ORCHESTRATOR], "/work/ORCHESTRATOR"]])
  end

  it "leaves a working session alone" do
    pass(roster_of("miette"))
    expect(shell.resumes).to be_empty
  end

  it "brings the Claude daemon up before it resumes anything", :aggregate_failures do
    shell.daemon_up = false
    pass
    expect(shell.detached).to eq([%w[claude daemon run]])
    expect(shell.calls.index { |call| call[:argv].include?("--resume") }).to be > 0
  end

  it "writes the loops the resumed session is to re-arm" do
    pass
    loops = JSON.parse(File.read(File.join(home, "loops.json")))
    expect(loops["ORCHESTRATOR"]).to eq([loop_row])
  end

  it "records a resumed session whose loops were never armed" do
    pass
    now[0] += 200
    pass
    expect(journal.map { |line| line["kind"] }).to include("resumed", "loops_missing")
  end

  it "records the loops armed once the session's start hook has run" do
    pass
    FileUtils.mkdir_p(File.join(home, "armed"))
    FileUtils.touch(File.join(home, "armed", "ORCHESTRATOR"), mtime: Time.at(1_050))
    now[0] += 60
    pass
    expect(journal.map { |line| line["kind"] }).to include("loops_armed")
  end

  it "records a mass kill when pinned sessions vanish within a minute", :aggregate_failures do
    pass(roster_of("ORCHESTRATOR", "miette"))
    shell.listed = [entry("ORCHESTRATOR", "stopped"), entry("miette", "stopped")]
    now[0] += 30
    pass(roster_of("ORCHESTRATOR", "miette"))
    expect(journal.map { |line| line["kind"] }).to include("mass_kill")
    expect(journal.find { |line| line["kind"] == "mass_kill" }["detail"]).to include("sessions" => %w[miette])
  end

  it "never signals a process", :aggregate_failures do
    pass
    expect(shell.calls.flat_map { |call| call[:argv] }).not_to include("kill", "stop", "rm")
    sources = Dir[File.join(__dir__, "../lib/hecks/hecks/adapters/guarding/**/*.rb")].map { |file| File.read(file) }
    expect(sources.join).not_to match(/Process\.kill|\bkill\b/)
  end
end
