# frozen_string_literal: true

require "spec_helper"
require "hecks/hecks/adapters/work_limits"
require "hecks/hecks/adapters/dispatching"
require "hecks/hecks/adapters/codebase/heavy_slots"
require "hecks/pipeline_board/adapters/load_guard"

# While the owner has `signalbox_pressure` drive them, the load guards, the moving cap and the
# heavy-jobs gate read Signalbox's one pressure signal (ADR 0222, phase 3b) instead of their own
# readings; without a current signal each keeps its own.
RSpec.describe "the readers of Signalbox's pressure signal" do
  let(:short) { { band: "short", headroom: -400, coders_fit: 0, gates_fit: 0 } }
  let(:tight) { { band: "tight", headroom: 5000, coders_fit: 3, gates_fit: 1 } }

  def guard(signal, load: 30.0)
    Hecks::Adapters::PipelineBoard::LoadGuard.new(limit: -> { 10.0 }, load: -> { load }, pressure: -> { signal })
  end

  def cap_registry
    world = Struct.new(:lines) { def for_verb(verb) = lines[verb] }.new({ "work_cap" => { moves: true, least: 2, most: 6 } })
    Struct.new(:world_of) do
      def world(_name) = world_of

      def bluebook(_name) = nil
    end.new(world)
  end

  it "the board's guard is loaded in the short band whatever the load" do
    expect(guard(short, load: 1.0).loaded?).to be(true)
  end

  it "the board's guard is not loaded in the tight band whatever the load" do
    expect(guard(tight, load: 30.0).loaded?).to be(false)
  end

  it "the board's guard keeps its own load limit while the signal does not drive" do
    expect(guard(nil, load: 30.0).loaded?).to be(true)
  end

  it "the moving cap stands at the started work items and the coders that fit" do
    expect(Hecks::Adapters::MovingCap.standing(cap_registry, signal: tight)[:current]).to eq(3)
  end

  it "the moving cap holds at its least in the short band" do
    expect(Hecks::Adapters::MovingCap.standing(cap_registry, signal: short)[:current]).to eq(2)
  end

  it "the heavy-jobs gate takes the gates that fit, at least one" do
    root = File.expand_path("..", __dir__)
    expect(Hecks::Adapters::Codebase::HeavySlots.cap_of(root, signal: short)).to eq(1)
  end

  it "the fill pauses in the short band, naming the signal" do
    paused = Hecks::Adapters::Dispatching::PressureLimits.of(nil, signal: short)[:paused]
    expect(paused).to eq("skipped: pressure short: pressure short (Signalbox): 0 coders fit, 0 gates fit")
  end

  it "the fill drops the load average as a limit of its own while the signal drives", :aggregate_failures do
    limits = Hecks::Adapters::Dispatching::PressureLimits.of(nil, signal: tight)
    expect(limits).to include(paused: nil, headroom: 3, per_session: nil)
    expect(limits[:max_load]).to eq(Float::INFINITY)
  end

  it "the fill keeps its own limits while the signal does not drive" do
    expect(Hecks::Adapters::Dispatching::PressureLimits.of(nil)).to eq({})
  end
end
