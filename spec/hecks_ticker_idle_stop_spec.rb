require "spec_helper"
require "tmpdir"
require "hecks/hecks/adapters/dispatching"
require "hecks/hecks/adapters/ticking"
require_relative "support/stall_watch_looks"

# Starts a `Ticker` chain with a recorder where the `Ticking` port would start its process, and
# writes the tap lines of that chain, for the group that includes it.
module TickerIdleLooks
  def run = "1c9febcb082012f5bd1bafd792685b5d685b5feb"

  def ticking
    Hecks::Adapters::Ticking.new(registry: registry, root: Dir.pwd, settings: {
                                   spawner: ->(*) {}, seconds: 20, minutes: 1, persisted: true, dir: dir
                                 })
  end

  def start_chain
    lookup = ->(port, _asked) { port.to_s == "Ticking" ? ticking : nil }
    Hecks::Runtime::AdapterLookup.standing_in(lookup) { dispatch("Hecks::Ticker.Start", run: { value: run }) }
  end

  def write_chain(*rows)
    lines = rows.each_with_index.map { |(event, ago), seq| line(seq + 1, event, run, ago).merge(aggregate: "Hecks::Ticker") }
    File.write(tap, lines.map { |entry| JSON.generate(entry) }.join("\n") << "\n")
  end

  def stopped = registry.event_log.select { |event| event.name == "TickerStopped" }
end

# A chain whose process was killed leaves its `Ticker` ticking for good. The StallWatch
# `ticker-idle` row files it once it has ticked past its own limit, and `StopTickerWhenIdle`
# ends it; no Work item is planned for it. The domain is in Memory and the tap is a temp file.
RSpec.describe "a ticker left ticking is stopped", :aggregate_failures do
  include_context "with a stall watch tap"
  include TickerIdleLooks

  before { start_chain }

  it "stops a chain that has ticked for 45 minutes, and plans no work item" do
    write_chain(["TickerBegun", 45])
    detect("look-1")

    expect(stopped.size).to eq(1)
    expect(keys("Tickets", "Work", :work)).to be_empty
  end

  it "leaves a chain that began 10 minutes ago" do
    write_chain(["TickerBegun", 10])
    detect("look-1")

    expect(stopped).to be_empty
  end

  it "stops nothing for a chain that ended on its own" do
    write_chain(["TickerBegun", 45], ["TickerStopped", 30])
    detect("look-1")

    expect(stopped).to be_empty
  end
end
