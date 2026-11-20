# frozen_string_literal: true

require "spec_helper"
require "hecks/hecks/adapters/claude_cleaning"

# The owner's `reaping.signalbox` switch, read from the Tickets world's `reaping` line. It fails
# safe to off: a world with no such line, or no registry, keeps the plain sweep.
RSpec.describe Hecks::Adapters::ClaudeCleaning::ReapingSwitch do
  def registry(line) = double(world: double(for_verb: line))

  it "is off while the Tickets world declares no reaping line" do
    expect(described_class.on?(registry(nil))).to be(false)
  end

  it "is off as declared" do
    expect(described_class.on?(registry({ signalbox: false }))).to be(false)
  end

  it "is on once turned" do
    expect(described_class.on?(registry({ "signalbox" => true }))).to be(true)
  end

  it "is off when no registry is booted" do
    expect(described_class.on?(nil)).to be(false)
  end
end
