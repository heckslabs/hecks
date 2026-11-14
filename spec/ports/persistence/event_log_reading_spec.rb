require "hecks"

RSpec.describe Hecks::Ports::Persistence::EventLogReading do
  let(:host) { Class.new { include Hecks::Ports::Persistence::EventLogReading } }

  # A repository over `adapter` whose whole-log read answers `log`.
  def repository(adapter, log = nil)
    built = host.new
    built.instance_variable_set(:@adapter, adapter)
    built.define_singleton_method(:events) { log }
    built
  end

  it "reads past a position by the adapter's own lookup when it has one" do
    expect(repository(double(events_past: [:new])).events_past(2)).to eq([:new])
  end

  it "cuts the whole log for an adapter with no lookup of its own" do
    expect(repository(Object.new, %i[a b c]).events_past(2)).to eq([:c])
  end

  it "counts by the adapter's own count, else the whole log", :aggregate_failures do
    expect(repository(double(event_count: 7)).event_count).to eq(7)
    expect(repository(Object.new, %i[a b]).event_count).to eq(2)
    expect(repository(Object.new).event_count).to eq(0)
  end
end
