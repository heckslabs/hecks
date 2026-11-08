require "spec_helper"
require "hecks/hecks/adapters/machine_sampling"

# The machine's figures are read behind the port from what `top`, `sysctl` and `uptime` print.
RSpec.describe Hecks::Adapters::MachineSampling::Readings do
  let(:readings) { described_class.new(shell: nil) }
  let(:top) { "CPU usage: 28.7% user, 11.2% sys, 60.1% idle\nPhysMem: 35G used (2G wired, 17G compressor), 101M unused." }

  it "reads the CPU idle percentage and the compressor's size", :aggregate_failures do
    expect(readings.idle(top)).to eq(60.1)
    expect(readings.compressor(top)).to eq(17.0)
  end

  it "reads swap used as a percentage of swap total" do
    expect(readings.swap("total = 12288.00M  used = 10547.31M  free = 1740.69M  (encrypted)")).to eq(85.8)
  end

  it "reads nothing from a machine with no swap or no figures", :aggregate_failures do
    expect(readings.swap("total = 0.00M  used = 0.00M  free = 0.00M")).to be_nil
    expect(readings.idle("")).to be_nil
  end

  it "refuses a second reading within the interval" do
    sampling = Hecks::Adapters::MachineSampling.new(settings: { readings: -> { {} }, clock: -> { 5.0 } })
    Hecks::Adapters::MachineSampling.last = nil
    sampling.read

    expect { sampling.read }.to raise_error(Hecks::Adapters::ConsoleCapture::Failure, /seconds ago/)
  end
end
