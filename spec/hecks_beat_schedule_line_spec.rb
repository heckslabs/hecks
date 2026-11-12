require "spec_helper"
require "cgi"
require "shellwords"
require "hecks/hecks/adapters/main_integration"

# The command line the beat job runs, checked by the launcher's own reading of it: the line is
# taken from the rendered property list, resolved against a booted Hecks, and its arguments are
# parsed by the launcher's argument parser. Nothing is dispatched and nothing is written.
RSpec.describe Hecks::Adapters::MainIntegration::BeatSchedule, "#plist" do
  let(:runner) { Hecks::Adapters::Driving::CliRunner }
  let(:hecks) { @hecks ||= boot_hecks_in_memory }
  let(:schedule) { described_class.new(root: "/train", home: "/nowhere", runner: ->(_argv) { ["", true] }) }

  def beat_line(plist)
    script = CGI.unescapeHTML(plist[%r{<string>(cd .*?)</string>}m, 1])
    script.lines.find { |line| line.start_with?("exe/hecks") }.sub("$(date +%s)", "1700000000")
  end

  def launcher_words(line) = Shellwords.split(line.split(" >").first).drop(1)

  def resolved(words) = runner.resolve(hecks, words, "hecks")

  it "resolves to Heartbeat.Beat! with no refusal", :aggregate_failures do
    plan = resolved(launcher_words(beat_line(schedule.plist)))
    expect(plan[:answer]).to be_nil
    expect(plan[:name]).to eq("heartbeat.beat")
  end

  it "hands the beat key to the launcher's argument parser as a bare argument" do
    plan = resolved(launcher_words(beat_line(schedule.plist)))
    args = Hecks::Adapters::Driving::Cli.arguments(plan[:spec], plan[:rest] - ["--wait"])
    expect(args).to eq(beat: { value: "launchd-1700000000" })
  end

  it "is refused by the bang rule when the bang is left off", :aggregate_failures do
    words = launcher_words(beat_line(schedule.plist)).map { |word| word.sub("Beat!", "Beat") }
    text, status = resolved(words)[:answer]
    expect(text).to include("is a command and writes; write it as Heartbeat.Beat!")
    expect(status).to eq(Hecks::Adapters::Driving::ExitStatus::USAGE)
  end
end
