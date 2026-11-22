# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "hecks/hecks/adapters/guarding"

# The `Guarding` port's adapter writes the watchdog's launchd job and its roster, or says what it
# would write; the runner stands in for `launchctl`, so nothing is loaded.
RSpec.describe Hecks::Adapters::Guarding do
  let(:home) { Dir.mktmpdir("guarding") }
  let(:asked) { [] }
  let(:runner) { ->(argv) { (asked << argv) && ["", true] } }
  let(:guarding) { described_class.new(settings: { home: home, runner: runner }) }
  let(:agent) { File.join(home, "Library/LaunchAgents/dev.hecks.watchdog.plist") }

  after { FileUtils.rm_rf(home) }

  it "writes nothing and loads nothing unconfirmed", :aggregate_failures do
    report = guarding.guard(run: { value: "w" }, confirm: false)
    expect(report.dig(:report, :value)).to include("would write", "<key>KeepAlive</key>")
    expect(File).not_to exist(agent)
    expect(asked).to be_empty
  end

  it "writes a job kept alive at normal priority and copies the loop, once confirmed", :aggregate_failures do
    guarding.guard(run: { value: "w" }, confirm: true)
    expect(File.read(agent)).to include("<key>KeepAlive</key>", "<string>Standard</string>", "watch.rb")
    expect(File).to exist(File.join(home, ".claude/hecks-dev/watchdog/bin/pass.rb"))
    expect(asked.last.first(2)).to eq(%w[launchctl bootstrap])
  end

  it "removes the job it wrote", :aggregate_failures do
    guarding.guard(run: { value: "w" }, confirm: true)
    guarding.release(run: { value: "w" }, confirm: true)
    expect(File).not_to exist(agent)
    expect(asked.last.first(2)).to eq(%w[launchctl bootout])
  end
end
