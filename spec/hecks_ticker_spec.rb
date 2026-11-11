require "spec_helper"
require_relative "support/ticker_chain"

# A queued train pull request gets one chain of ticks that beats the clock: it starts once per
# boarded commit, each tick beats `Heartbeat`, and the chain is over when the domain says so (a
# stop, or beats past the limit the world allows). The domain is in Memory and the process the
# `Ticking` port would start is a recorder.
RSpec.describe "the chain of ticks that beats the clock for a queued train pull request" do
  include TickerChain

  before(:all) { @hecks = boot_hecks_in_memory }

  it "starts the chain with the beats the world allows", :aggregate_failures do
    start("run-a")
    expect(started.size).to eq(1)
    expect(names).to include("TickerBegun")
  end

  it "starts no second chain for the same boarded commit", :aggregate_failures do
    start("run-b")
    expect { start("run-b") }.to raise_error(Hecks::Runtime::AlreadyExists)
    expect(started.size).to eq(1)
  end

  it "beats the clock on a tick" do
    start("run-c")
    expect { tick("run-c", 1) }.to(change { names.count("Beaten") }.by(1))
  end

  it "refuses a tick once the beats pass the limit" do
    start("run-d")
    expect { tick("run-d", 4) }.to raise_error(StandardError, /limit/)
  end

  it "refuses a tick once the chain is stopped" do
    start("run-e")
    dispatch("Ticker.Stop", ticker: "run-e", ending: "merged")
    expect { tick("run-e", 1) }.to raise_error(StandardError)
  end
end
