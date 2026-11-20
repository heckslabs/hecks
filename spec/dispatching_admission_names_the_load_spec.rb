# frozen_string_literal: true

require "spec_helper"
require_relative "support/load_band_readings"

# The reopened probe of 2026-11-20 05:30 read 9086 MB at the OS's normal level as short. The band
# is the worse of the memory and load bands, so a fill's clause sets the load and its marks beside
# the memory facts. A load that holds the band tight holds a lower-tier coder's start, as a short
# one does, each by its own given.
RSpec.describe Hecks::Adapters::Dispatching::Admitting do
  include LoadBandReadings

  it "holds a lower-tier coder at 9086 MB while the load holds the band tight" do
    expect(admitting("tight", 1055).reason(item)).to include("no lower-tier coder or helper starts while pressure is tight")
  end

  it "holds that coder while the load reads the band short" do
    expect(admitting("short", 1900).reason(item)).to include("only an urgent coder is admitted while pressure is short")
  end

  it "names the load, its cores and the world's marks in its clause" do
    expect(admitting("short", 1900).clause).to include("gap 2048; load 19.00 on 6 cores, tight 150%, short 300% of cores;")
  end

  it "keeps the memory facts in its clause beside the load" do
    expect(admitting("tight", 1055).clause).to include("(tight; memory pressure level 1; draw 397 metered, floor 3072")
  end
end
