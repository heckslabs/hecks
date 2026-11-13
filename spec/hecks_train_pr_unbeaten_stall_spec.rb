require "spec_helper"
require "tmpdir"
require "hecks/hecks/adapters/dispatching"
require_relative "support/stall_watch_looks"

# Tap lines of one `Ticker` chain, and the keys a look filed, for the train-pr-unbeaten group.
module TrainPrUnbeatenLooks
  # The boarded commit the chain is keyed by.
  SHA = "1c9febcb082012f5bd1bafd792685b5d685b5feb".freeze

  def write_ticker(rows)
    lines = rows.each_with_index.map { |(event, ago), seq| line(seq + 1, event, SHA, ago).merge(aggregate: "Hecks::Ticker") }
    File.write(tap, lines.map { |entry| JSON.generate(entry) }.join("\n") << "\n")
  end

  def keys(domain, name, field)
    aggregate = registry.bluebook(domain).aggregate(name)
    registry.repository(domain, aggregate).all.map { |record| Hecks::Adapters::StartedWork.value(record, field).to_s }
  end

  def stall = "stall-train-pr-unbeaten-#{SHA}"
end

# A queued train pull request asks for a chain of ticks (`Ticker.TickerRequested`, keyed by the
# boarded commit); a chain that never beats within the `train-pr-unbeaten` row's minutes is a stall
# naming the commit. A beat or a stopped chain closes it; a declined start does not.
RSpec.describe "StallWatch train-pr-unbeaten" do
  include_context "with a stall watch tap"
  include TrainPrUnbeatenLooks

  it "files a chain asked for 9 minutes ago that never beat, naming the commit", :aggregate_failures do
    write_ticker([["TickerRequested", 9]])
    detect("look-1")

    expect(keys("Hecks", "Stall", :stall)).to eq([stall])
    expect(keys("Tickets", "Work", :work)).to eq([stall])
  end

  # What a look files for each tap: a young chain, one that beat, one stopped, and one declined
  # (a declined start is no worker, so it stays a stall).
  {
    "a chain asked for 2 minutes ago"  => [[["TickerRequested", 2]], false],
    "a chain that beat"                => [[["TickerRequested", 9], ["Ticked", 8]], false],
    "a chain that stopped"             => [[["TickerRequested", 9], ["TickerStopped", 8]], false],
    "a chain whose start was declined" => [[["TickerRequested", 9], ["TickerDeclined", 9]], true]
  }.each do |name, (rows, filed)|
    it "files #{filed ? "a stall" : "nothing"} for #{name}" do
      write_ticker(rows)
      detect("look-1")

      expect(keys("Hecks", "Stall", :stall)).to eq(filed ? [stall] : [])
    end
  end

  it "carries a move the orchestrator runs: a beat, then an advance" do
    write_ticker([["TickerRequested", 9]])

    expect(watching.unclosed(run: "look-1").first[:detail]).to include("Heartbeat.beat!", "Integration.advance!")
  end
end
