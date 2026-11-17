# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "hecks/hecks/adapters/codebase/heavy_slots"

# Helpers for a gate that waited on a taken slot, gave up, and started child checks.
module GateSlotOnceHelpers
  SLOTS = Hecks::Adapters::Codebase::HeavySlots

  # Runs a gate that gives up waiting, then three child checks that each ask for a slot.
  def given_up_gate(dir)
    clock = [0, 100_000, 100_000].each.method(:next).to_proc
    gate = SLOTS.new(cap: 1, dir: dir, base: {}, err: StringIO.new, clock: clock, pause: ->(_) {})
    gate.hold("gate") { Array.new(3) { child(dir).hold("check") { :child_ran } }.last }.first
  end

  # A child sees the environment the gate set, as a started process does; a wait would raise.
  def child(dir) = SLOTS.new(cap: 1, dir: dir, base: ENV, err: StringIO.new, pause: ->(_) { raise "queued" })

  def waiters(dir) = Dir.glob(File.join(dir, "waiting", "*")).select { |path| File.file?(path) }
end

# A gate takes the heavy-job slot once: the checks it starts run inside its hold and never add a
# waiter to the queue, whether the gate got a place or gave up waiting for one.
RSpec.describe Hecks::Adapters::Codebase::HeavySlots, "#hold by a gate" do
  include GateSlotOnceHelpers

  let(:dir) { Dir.mktmpdir("gate-slot-once") }
  let(:other_job) { File.new(File.join(dir, "slot-0.lock"), File::CREAT | File::RDWR, 0o600) }

  before { other_job.flock(File::LOCK_EX) }

  after do
    other_job.close
    FileUtils.rm_rf(dir)
  end

  it "runs each child check at once after the gate gave up waiting" do
    expect(given_up_gate(dir)).to eq([:child_ran, ""])
  end

  it "adds no waiter to the queue for the gate's children" do
    given_up_gate(dir)
    expect(waiters(dir)).to eq([])
  end
end
