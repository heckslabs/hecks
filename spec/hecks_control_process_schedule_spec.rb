require "spec_helper"
require "tmpdir"
require "hecks/hecks/adapters/main_integration"

# The control process is kept up by a launchd job Hecks writes, as it keeps the Claude daemon: the
# primary checkout's resident, started in control mode, restarted by launchd when it exits.
RSpec.describe "the control process job" do
  let(:schedule_class) { Hecks::Adapters::MainIntegration::ControlProcessSchedule }
  let(:home) { Dir.mktmpdir("hecks-control-process") }
  let(:calls) { [] }
  let(:runner) { ->(argv) { (calls << argv) && ["", true] } }
  let(:schedule) { schedule_class.new(root: "/primary", home: home, runner: runner) }

  after { FileUtils.remove_entry(home) }

  it "keeps the primary's resident up in control mode", :aggregate_failures do
    expect(schedule.plist).to include("<key>KeepAlive</key>\n  <true/>")
    expect(schedule.plist).to include("/primary/exe/hecks").and include("--control")
  end

  it "loads the job when confirmed and unloads it when withdrawn", :aggregate_failures do
    schedule.install(confirm: true)
    expect(calls.map { |argv| argv[1] }).to eq(%w[bootout bootstrap])
    schedule.uninstall(confirm: true)
    expect(File.exist?(schedule.path)).to be(false)
  end

  it "writes nothing unconfirmed" do
    expect(schedule.install(confirm: false)).to start_with("would write")
  end
end
