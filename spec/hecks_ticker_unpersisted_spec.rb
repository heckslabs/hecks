require "spec_helper"
require_relative "support/ticker_chain"

# A chain whose ticks each read the Ticker record back in their own process cannot work when the
# Ticker is in Memory, so the port declines to start one and the domain records why.
RSpec.describe "the chain of ticks for a Ticker that is not persisted" do
  include TickerChain

  before(:all) { @hecks = boot_hecks_in_memory }

  def ticking
    @ticking ||= Hecks::Adapters::Ticking.new(
      registry: @hecks.registry, root: Dir.pwd,
      settings: { spawner: ->(*argv) { started << argv }, seconds: 20, minutes: 1, dir: Dir.mktmpdir("ticker-logs") }
    )
  end

  it "starts no chain", :aggregate_failures do
    start("run-memory-a")
    expect(started).to be_empty
    expect(names).to include("TickerDeclined")
  end

  it "says in the decline that the Ticker is in Memory" do
    start("run-memory-b")
    declined = @hecks.registry.event_log.find { |event| event.name == "TickerDeclined" }
    expect(declined.to_h[:payload][:ending].value).to include("in Memory")
  end
end
