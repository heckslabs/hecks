# frozen_string_literal: true

require "spec_helper"
require "hecks/hecks/adapters/dispatching"
require "hecks/hecks/adapters/machine_sampling"
require "hecks/pipeline_board/adapters/load_guard"

# The `load_average` dial of the Tickets world names which average the fill reads: 1, 5 or 15
# minutes, 5 when the world names none. The fill's limit, the expedite bar, the Machine's readings
# and the board's guard all read the one average the dial names.
RSpec.describe Hecks::Adapters::LoadAverage do
  let(:uptime) { "13:00  up 3 days,  load averages: 23.41 18.00 12.50" }
  let(:linux) { " 13:00:01 up 3 days, load average: 0.52, 0.58, 0.59" }
  let(:settings_class) { Hecks::Adapters::Dispatching::Settings }
  let(:guard) { Hecks::Adapters::PipelineBoard::LoadGuard }

  def registry(minutes)
    settings = minutes.nil? ? {} : { "load_average" => { minutes: minutes } }
    world = Hecks::Bluebook::World.new(domain: "Tickets", settings: settings)
    instance_double(Hecks::Runtime::Registry, world: world, bluebook: nil)
  end

  it "reads the 5-minute average when the world names none", :aggregate_failures do
    expect(described_class.minutes(registry(nil))).to eq(5)
    expect(settings_class.uptime_load(uptime)).to eq(18.0)
  end

  it "reads the 1 or the 15-minute average when the dial names it", :aggregate_failures do
    expect(settings_class.new(registry(1), load: nil).load_minutes).to eq(1)
    expect(settings_class.uptime_load(uptime, minutes: 1)).to eq(23.41)
    expect(settings_class.uptime_load(linux, minutes: 15)).to eq(0.59)
  end

  it "reads 5 minutes when the dial holds a figure that is not an average" do
    expect(described_class.minutes(registry(7))).to eq(5)
  end

  it "makes the fill's load the dial's average", :aggregate_failures do
    allow(settings_class).to receive(:uptime_load).and_return(11.0)
    settings_class.new(registry(15)).load

    expect(settings_class).to have_received(:uptime_load).with(minutes: 15)
  end

  it "reads the named column of the system's load averages", :aggregate_failures do
    allow(File).to receive(:readable?).with("/proc/loadavg").and_return(true)
    allow(File).to receive(:read).with("/proc/loadavg").and_return("1.5 2.5 3.5 1/200 99\n")

    expect(guard.reading).to eq(2.5)
    expect(guard.reading(15)).to eq(3.5)
  end
end
