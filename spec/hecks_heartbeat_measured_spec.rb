require "spec_helper"
require_relative "support/beat_places"

# A beat is measured: when the reactions it started have ended, the time and CPU each one spent
# are recorded on the beat, so the step that holds a tick up is named from the record.
RSpec.describe "a heartbeat's measure" do
  include BeatPlaces

  let(:dir) { Dir.mktmpdir("beat-measure") }
  let(:steps) { [{ policy: "Slow", ms: 9.0, cpu_ms: 8.0, self_ms: 9.0, self_cpu_ms: 8.0, depth: 1 }] }
  let(:measuring) { measuring_place(dir) }

  after { clean_place(dir) }

  it "asks to hear the cascade of the beat it takes" do
    expect(listeners_after_taking(measuring[:place]).size).to eq(1)
  end

  it "records the steps the cascade timed on the beat" do
    listeners_after_taking(measuring[:place]).each { |listener| listener.call(steps) }
    expect(measuring[:recorded]).to eq([["beat-1", steps]])
  end

  it "asks nothing of a registry it was not given" do
    expect(Hecks::Adapters::Beating.new(settings: { dir: dir }).take(beat: { value: "b" })).to eq({})
  end

  it "records a measured beat in the domain", :aggregate_failures do
    names = beat_names(dir, "beat-measured")

    expect(names).to include("Beaten", "BeatMeasured")
    expect(names.index("BeatMeasured")).to be > names.index("Beaten")
  end
end
