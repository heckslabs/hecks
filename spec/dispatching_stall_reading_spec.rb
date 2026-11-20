require "spec_helper"
require "hecks/hecks/adapters/dispatching"

# The reading and the governor of each kind of hold, worded from the plan's own reasons.
RSpec.describe Hecks::Adapters::Dispatching::StallReading do
  let(:skip) { Hecks::Adapters::Dispatching::Plan::Skip }
  let(:machine) { { load: 22.84, source: "roundhouse", max_load: 30.0, load_high: 22.0, rolling: true, waiting: 3 } }

  def reading(*reasons) = described_class.new(reasons.map { |reason| skip.new("item", reason) }, **machine).to_h

  it "names the load mark a pause by load is judged against", :aggregate_failures do
    said = reading(Hecks::Adapters::Dispatching::Plan::LOAD_PAUSE, "skipped: frozen (x)", Hecks::Adapters::Dispatching::Plan::LOAD_PAUSE)

    expect(said[:reason]).to eq("2 held by load pause")
    expect(said[:reading]).to eq("load 22.8 from roundhouse against load_high 22.0")
    expect(said[:governed_by]).to include("machine_marks load_high", "LoadFellBelow")
  end

  it "names Signalbox's admission and its given" do
    said = reading("skipped: signalbox: the band is short")

    expect(said).to include(reason: "1 held by signalbox admission", reading: "signalbox: the band is short")
  end

  it "names the owner's pause over whatever the plan says" do
    machine[:rolling] = false

    expect(reading("skipped: frozen (x)")).to include(reason: "3 held by owner pause")
  end

  it "says a wait no kind names in the plan's own words", :aggregate_failures do
    said = reading("skipped: something new")

    expect(said).to include(reason: "1 held by other", reading: "something new")
    expect(said[:governed_by]).to eq(described_class::UNNAMED)
  end
end
