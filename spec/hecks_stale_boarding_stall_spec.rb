require "spec_helper"
require "tmpdir"
require "hecks/hecks/adapters/dispatching"
require_relative "support/stall_watch_looks"

# Tap lines of one `Integration`, keyed by its run, for the stale-boarding group.
module StaleBoardingLooks
  # What a look files for each tap: a young boarding, one closed three ways, and one that
  # another run pushed.
  CASES = {
    "a boarding begun 2 minutes ago" => [[["MainBoardingStarted", "aaa111", 2]], false],
    "a boarding that pushed"         => [[["MainBoardingStarted", "aaa111", 15], ["MainPushed", "aaa111", 14]], false],
    "a boarding that was refused"    => [[["MainBoardingStarted", "aaa111", 15], ["MainPushRefused", "aaa111", 14]], false],
    "a boarding that was superseded" => [[["MainBoardingStarted", "aaa111", 15], ["IntegrationSuperseded", "aaa111", 14]], false],
    "a boarding another run pushed"  => [[["MainBoardingStarted", "aaa111", 15], ["MainPushed", "bbb222", 14]], true]
  }.freeze

  def write_integration(rows)
    lines = rows.each_with_index.map { |(event, id, ago), seq| line(seq + 1, event, id, ago).merge(aggregate: "Hecks::Integration") }
    File.write(tap, lines.map { |entry| JSON.generate(entry) }.join("\n") << "\n")
  end

  def keys(domain, name, field)
    aggregate = registry.bluebook(domain).aggregate(name)
    registry.repository(domain, aggregate).all.map { |record| Hecks::Adapters::StartedWork.value(record, field).to_s }
  end

  def stall(run = "aaa111") = "stall-stale-boarding-#{run}"
end

# A boarding left unpushed past the `stale-boarding` row's minutes is a stall naming its run. Its
# push, its refusal or its superseding closes it; another run's push does not.
RSpec.describe "StallWatch stale-boarding" do
  include_context "with a stall watch tap"
  include StaleBoardingLooks

  it "files a boarding begun 15 minutes ago, naming the run and its Work item", :aggregate_failures do
    write_integration([["MainBoardingStarted", "aaa111", 15]])
    detect("look-1")

    expect(keys("Hecks", "Stall", :stall)).to eq([stall])
    expect(keys("Tickets", "Work", :work)).to eq([stall])
  end

  StaleBoardingLooks::CASES.each do |name, (rows, filed)|
    it "files #{filed ? "a stall" : "nothing"} for #{name}" do
      write_integration(rows)
      detect("look-1")

      expect(keys("Hecks", "Stall", :stall)).to eq(filed ? [stall] : [])
    end
  end

  it "files a later boarding of a new run after the first closed", :aggregate_failures do
    write_integration([["MainBoardingStarted", "aaa111", 30], ["MainPushed", "aaa111", 29],
                       ["MainBoardingStarted", "ccc333", 15]])
    detect("look-1")

    expect(keys("Hecks", "Stall", :stall)).to eq([stall("ccc333")])
  end
end
