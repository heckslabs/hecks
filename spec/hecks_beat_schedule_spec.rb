require "spec_helper"
require "tmpdir"
require "hecks/hecks/adapters/main_integration"

# The launchd job that beats the clock from outside any process of the domain: its property list,
# its install and removal through a stand-in for `launchctl`, and the commands that ask for them
# through the `Integrating` port. Nothing here touches the real launch agents directory.
RSpec.describe Hecks::Adapters::MainIntegration::BeatSchedule do
  let(:home) { Dir.mktmpdir("hecks-beat-home") }
  let(:calls) { [] }
  let(:runner) { ->(argv) { calls.push(argv) && ["", true] } }
  let(:schedule) { described_class.new(root: "/train", home: home, runner: runner) }

  after { FileUtils.remove_entry(home) }

  it "beats once a minute through the train's launcher, with no pull request test of its own", :aggregate_failures do
    plist = schedule.plist
    expect(plist).to include("<integer>60</integer>", "cd /train || exit 1", "exe/hecks Heartbeat.Beat!")
    expect(plist).not_to include("gh ", "Ticker")
  end

  # Two real shells proved these lines by hand (a second tick ends at once, a killed holder frees
  # the lock); CI has no zsh to run them again, so this holds their place and order: the lock is
  # taken before the beat runs.
  it "takes the beat's lock before it runs the beat", :aggregate_failures do
    lines = CGI.unescapeHTML(schedule.plist[%r{<string>(cd .*?)</string>}m, 1]).lines.map(&:strip)

    expect(lines[1]).to match(%r{\Amkdir -p ".*/hecks-dev" && : >> ".*/train-beat\.lock"\z})
    expect(lines[2]).to match(%r{\Azmodload zsh/system && zsystem flock -t 0 ".*/train-beat\.lock" 2>/dev/null \|\| \{.*\}\z})
    expect(lines[3]).to eq(described_class::FOLLOW_MAIN)
    expect(lines[4]).to start_with("exe/hecks Heartbeat.Beat!")
  end

  # A tick that finds the lock held writes why it was skipped, so a beat that outruns its interval
  # is seen; the line is the report, and the skipped tick still starts no beat.
  it "reports a tick skipped while the beat before it still runs" do
    lines = CGI.unescapeHTML(schedule.plist[%r{<string>(cd .*?)</string>}m, 1]).lines.map(&:strip)

    expect(lines[2]).to include("beat skipped: the beat before it still runs", "#{home}/.claude/hecks-dev/train-beat.overrun.log")
  end

  it "writes nothing unconfirmed, and says what it would write", :aggregate_failures do
    expect(schedule.install(confirm: false)).to include("would write", schedule.path)
    expect([File.exist?(schedule.path), calls]).to eq([false, []])
  end

  it "writes the property list and loads it when confirmed", :aggregate_failures do
    schedule.install(confirm: true)
    expect(File.read(schedule.path)).to eq(schedule.plist)
    expect(calls.last.first(2)).to eq(%w[launchctl bootstrap])
  end

  it "replaces a job already loaded, so an install twice leaves one job" do
    2.times { schedule.install(confirm: true) }
    expect(calls.count { |argv| argv[1] == "bootstrap" }).to eq(2)
  end

  it "refuses by name when launchd refuses the job" do
    refusing = described_class.new(root: "/train", home: home, runner: ->(argv) { ["no", argv[1] != "bootstrap"] })
    expect { refusing.install(confirm: true) }.to raise_error(Hecks::Adapters::ConsoleCapture::Failure, /launchctl refused/)
  end

  it "unloads and removes an installed job", :aggregate_failures do
    schedule.install(confirm: true)
    expect(schedule.uninstall(confirm: true)).to eq("removed dev.hecks.train-beat")
    expect(File.exist?(schedule.path)).to be(false)
  end

  it "says so when there is no job to remove" do
    expect(schedule.uninstall(confirm: true)).to include("is not installed")
  end
end
