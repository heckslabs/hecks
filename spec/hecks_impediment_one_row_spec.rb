require "spec_helper"
require "tmpdir"
require "hecks/hecks/adapters/dispatching"
require_relative "support/impediment_looks"

# A stall session reads the one impediment it was woken for, not the whole view.
RSpec.describe "StallWatch impediments named by one stall" do
  include_context "with a stall watch tap"
  include ImpedimentLooks

  before { write_sources(ImpedimentLooks::STANDING) }

  def one(key) = watching.impediments(run: "look-1", stall: key)

  it "answers only the named row of a view of many" do
    expect(one("stall-held-lock-hold-1").map { |row| row[:stall_kind] }).to eq(["held-lock"])
  end

  it "answers a folded row under its kind's key" do
    expect(one("stall-codebase-check-failed").map { |row| row[:count] }).to eq([2])
  end

  it "answers nothing for an unknown key" do
    expect(one("no-such-stall")).to eq([])
  end

  it "answers the whole view when no key is given" do
    expect(impediments.size).to eq(4)
  end
end
