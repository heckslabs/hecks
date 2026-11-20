# frozen_string_literal: true

require "spec_helper"
require "json"
require "tmpdir"
require "hecks/signalbox/adapters/pressure_signal"

# The dark report says since when the posted signal has been dark and when it last posted.
RSpec.describe Hecks::Adapters::PressureSignal, ".dark_report" do
  let(:dir) { Dir.mktmpdir }
  let(:path) { File.join(dir, "pressure.json") }
  let(:posted) { Time.utc(2026, 11, 20, 16, 0, 0) }

  after { FileUtils.remove_entry(dir) }

  def post(at) = File.write(path, JSON.generate(posted_at: at.iso8601, stale_after: 120, band: "normal"))

  it "is nil while the signal is current" do
    post(posted)
    expect(described_class.dark_report(path: path, now: posted + 60)).to be_nil
  end

  it "says since when it is dark and when it last posted" do
    post(posted)
    report = described_class.dark_report(path: path, now: posted + 278)
    expect(report).to include(dark: true, since: "2026-11-20T16:02:00Z", last_post: "2026-11-20T16:00:00Z",
                              said: "signal dark since 2026-11-20T16:02:00Z, last post 2026-11-20T16:00:00Z")
  end

  it "says none was posted when the file is missing" do
    expect(described_class.dark_report(path: path, now: posted)[:said])
      .to eq("signal dark since never posted, last post never")
  end
end
