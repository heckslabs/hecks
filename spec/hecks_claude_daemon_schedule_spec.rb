require "spec_helper"
require "tmpdir"
require "hecks/hecks/adapters/main_integration"

# The Claude daemon is kept up by a launchd job Hecks writes: at normal priority, never niced, never
# Background, so every session the daemon hosts can run on the performance cores.
RSpec.describe "the Claude daemon job" do
  let(:schedule_class) { Hecks::Adapters::MainIntegration::ClaudeDaemonSchedule }
  let(:home) { Dir.mktmpdir("hecks-claude-daemon") }
  let(:calls) { [] }
  let(:runner) { ->(argv) { (calls << argv) && ["", true] } }
  let(:schedule) { schedule_class.new(home: home, runner: runner) }

  after { FileUtils.remove_entry(home) }

  it "runs at Standard QoS, at nice 0, with no low-priority IO", :aggregate_failures do
    expect(schedule.plist).to include("<key>ProcessType</key>\n  <string>Standard</string>")
    expect(schedule.plist).to include("<key>Nice</key>\n  <integer>0</integer>")
    expect(schedule.plist).not_to include("Background", "LowPriorityIO")
  end

  it "keeps the daemon alive and starts it with no nice wrapper", :aggregate_failures do
    expect(schedule.plist).to include("<key>KeepAlive</key>\n  <true/>")
    expect(schedule.plist).to include("daemon status").and include("exec")
    expect(schedule.plist).not_to match(/\bnice -n\b/)
  end

  it "reads the world's claude_daemon_job setting, and refuses Background", :aggregate_failures do
    world = Struct.new(:settings) { def for_verb(_verb) = settings }.new({ nice: 2 })
    registry = instance_double(Hecks::Runtime::Registry, world: world)
    expect(Hecks::Adapters::MainIntegration::JobPriority.from(registry, verb: "claude_daemon_job", nice: 0).to_h[:nice]).to eq(2)
    expect { Hecks::Adapters::MainIntegration::JobPriority.new(process_type: "Background") }.to raise_error(Hecks::Adapters::ConsoleCapture::Failure)
  end

  it "writes and loads the job when confirmed, replacing one already loaded", :aggregate_failures do
    schedule.install(confirm: true)
    expect(File.read(schedule.path)).to eq(schedule.plist)
    expect(calls.map { |argv| argv[1] }).to eq(%w[bootout bootstrap])
  end

  it "writes nothing unconfirmed, and removes the job on uninstall", :aggregate_failures do
    expect(schedule.install(confirm: false)).to start_with("would write")
    expect(File.exist?(schedule.path)).to be(false)
    schedule.install(confirm: true)
    schedule.uninstall(confirm: true)
    expect(File.exist?(schedule.path)).to be(false)
  end
end
