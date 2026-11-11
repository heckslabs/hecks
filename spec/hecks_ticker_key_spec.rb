require "spec_helper"
require_relative "support/ticker_chain"

# A tick finds its record by the run key the chain passes, so a missing record is refused by name.
RSpec.describe "the chain of ticks finding its record by the run key it passes" do
  include TickerChain

  before(:all) { @hecks = boot_hecks_in_memory }

  it "ticks the record the start made, addressed by the run" do
    start("run-f")
    expect { tick("run-f", 1) }.to(change { names.count("Ticked") }.by(1))
  end

  it "refuses by name a tick for a run no record holds" do
    expect { tick("run-never-started", 1) }.to raise_error(StandardError, /run-never-started|not found|no Ticker/i)
  end
end
