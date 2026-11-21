# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "hecks/agents/adapters/seat_marker"

# The seat a hand-started session takes is one line in a file the guard hook reads.
RSpec.describe Hecks::Adapters::SeatMarker do
  let(:dir) { Dir.mktmpdir("seats") }
  let(:marker) { described_class.new(settings: { dir: dir }) }

  after { FileUtils.remove_entry(dir) }

  def seat(role) = marker.seat(session: { value: "s1" }, role: { value: role })

  it "writes the role under the session" do
    seat("orchestrator")
    expect(File.read(File.join(dir, "s1"))).to eq("orchestrator\n")
  end

  it "replaces the role when the session registers again" do
    seat("orchestrator")
    seat("orchestrator-owner")
    expect(File.read(File.join(dir, "s1"))).to eq("orchestrator-owner\n")
  end

  it "refuses a session that is not a plain word" do
    expect { marker.seat(session: "../x", role: "orchestrator") }.to raise_error(ArgumentError)
  end
end
