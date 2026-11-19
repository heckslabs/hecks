# frozen_string_literal: true

require "spec_helper"
require "hecks/signalbox/adapters/pressure_posting"

# Signalbox posts the machine's one pressure signal (ADR 0222 law 2, phase 3b); every reader reads
# the posted file and compares nothing but its age, so a signal past its `stale_after` is dark.
RSpec.describe Hecks::Adapters::PressureSignal do
  let(:dir) { Dir.mktmpdir("pressure-signal") }
  let(:path) { File.join(dir, "signalbox", "pressure.json") }
  let(:posted) { Time.utc(2026, 11, 19, 12) }

  after { FileUtils.rm_rf(dir) }

  def post(band: "tight", coders: 2)
    held = { pressure: { value: "beat-1" }, band: band, headroom: { value: 4000 }, coders_fit: { value: coders } }
    Hecks::Adapters::PressurePosting.new(settings: { path: path, now: -> { posted } }).post(**held)
  end

  it "reads the posted band while the signal is current" do
    post
    expect(described_class.current(path: path, now: posted + 60)[:band]).to eq("tight")
  end

  it "is dark once the signal is older than its stale_after" do
    post
    expect(described_class.current(path: path, now: posted + 600)).to be_nil
  end

  it "is dark when no signal was posted" do
    expect(described_class.current(path: path)).to be_nil
  end

  it "says no room below nought" do
    expect(described_class.coders({ coders_fit: -3 })).to eq(0)
  end

  it "is read only while the Tickets world's switch drives it" do
    expect(described_class.drives?({ drives: false })).to be(false)
  end

  it "names the band and the room in a reason" do
    expect(described_class.said({ band: "short", coders_fit: 0, gates_fit: 0 })).to eq(
      "pressure short (Signalbox): 0 coders fit, 0 gates fit"
    )
  end
end
