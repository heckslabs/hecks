# frozen_string_literal: true

require "spec_helper"
require "hecks/hecks/adapters/work_limits"
require_relative "support/signalbox_door_wiring"
require_relative "support/roll_forward_fixtures"

# Admission reads the one pressure signal (ADR 0222 law 2). A beat from a linked worktree or the
# train copy is refused clearance and posts nothing, so the door answers from the signal a cleared
# beat posted, and is dark only when no current reading exists. Its dispatches begin their own
# cascade, so a start asked inside a Work item's reactions reads what a fill reads.
RSpec.describe Hecks::Adapters::Dispatching::SignalboxDoor do
  include SignalboxDoorWiring
  include RollForwardFixtures

  let(:worktree) { SignalboxDoorWiring::WORKTREE }

  def admitting(held) = Hecks::Adapters::Dispatching::Admitting.new(runs: {}, now: Time.now, door: held)

  def item = Hecks::Adapters::Dispatching::Plan::Item.new(key: "tiles", title: "tiles", priority: "next")

  it "answers its own cleared beat from the main checkout's view" do
    held = door
    expect(wired { held.look }).to include(band: "normal", headroom: 8209)
  end

  it "answers the posted band and headroom from a worktree's view while the signal is current" do
    held = door(view: worktree, signal: posted)
    expect(wired { held.look }).to include(band: "normal", headroom: 11_000)
  end

  it "keeps the marks and the draw of its own beat beside the posted signal" do
    held = door(view: worktree, signal: posted)
    expect(wired { held.look }).to include(floor: 3072, gap: 2048, draw: 1536, stale_after: 120)
  end

  it "is dark from a worktree's view when no signal is current" do
    held = door(view: worktree)
    expect(wired { held.look }[:band]).to eq("dark")
  end

  it "admits a coder from a worktree's view while the meter reads" do
    held = door(view: worktree, signal: posted)
    expect(wired { admitting(held).reason(item) }).to be_nil
  end

  it "keeps a start started: the cap check clears it with admission on" do
    limits = Hecks::Adapters::WorkLimits.new(registry: registry_of([double(work: "tiles", title: "tiles", status: "started",
                                                                           priority: "next")], { signalbox: true }),
                                             settings: { admitting: wired { admitting(door(view: worktree, signal: posted)) } })
    expect(wired { limits.check_cap(work: { value: "tiles" }) }[:output][:value]).to include("is admitted by")
  end

  it "holds every coder while no reading is current" do
    held = door(view: worktree)
    expect(wired { admitting(held).reason(item) }).to include("only the repair seat")
  end

  [4, 5].each do |level|
    it "reads the live band when asked at reaction depth #{level}" do
      held = door
      expect(wired { at_depth(level) { held.look } }[:band]).to eq("normal")
    end
  end

  it "puts the caller's reaction depth back after a look" do
    held = door
    expect(wired { at_depth(3) { held.look && Thread.current[:hecks_reaction_depth] } }).to eq(3)
  end

  it "says nothing of refused reactions while it looks" do
    held = door(view: worktree, signal: posted)
    expect { wired { held.look } }.not_to output(/was refused/).to_stderr
  end

  describe Hecks::Adapters::Dispatching::OwnCascade do
    after { Thread.current[described_class::DEPTH] = nil }

    def raising
      described_class.run { raise "boom" }
    rescue RuntimeError
      nil
    end

    it "puts the caller's depth back when the block raises" do
      Thread.current[described_class::DEPTH] = 4
      raising
      expect(Thread.current[described_class::DEPTH]).to eq(4)
    end
  end
end
