# frozen_string_literal: true

require "spec_helper"
require_relative "support/admission_beat"

# With admission by headroom on, the clock's beat reads Signalbox's room, not the static cap: the
# real Admitting puts each planned coder to `Admission.Admit` with the OS's memory pressure level,
# so a full cap with room for one wakes the beat and the roll's plan starts the item within one
# ramp window. A quiet beat names the given that held the room.
RSpec.describe "a beat that starts work Signalbox admits past the cap" do
  include AdmissionBeat

  let(:dispatching) { Hecks::Adapters::Dispatching }
  let(:wakes) { "a slot is free and a filling would start 1" }

  before do
    dispatching::Pending.reset!
    allow(dispatching::Settings).to(receive(:new).and_wrap_original do |original, *args, **options|
      original.call(*args, **options).tap { |held| allow(held).to receive(:roll_forward?).and_return(true) }
    end)
  end

  after { dispatching::Pending.reset! }

  def beat = beat_with(admission_settings)

  # The report of the roll the beat starts, planned as a rolling fill plans, without launching.
  def roll_plan
    filling = dispatching.new(registry: boot_hecks_in_memory.registry, settings: admission_settings)
    filling.choose(repo: { value: Dir.pwd }, rolling: { value: true }).dig(:report, :value)
  end

  it "wakes for the coder Signalbox admits at memory pressure level 1 though the cap is full" do
    expect(beat).to eq(wakes)
  end

  it "plans the roll that beat starts to start the item" do
    expect(roll_plan).to include("would start tiles")
  end

  it "stays quiet inside the ramp window and names the ramp" do
    started_ago(30)
    expect(beat).to match(/\Aquiet: nothing has become eligible by the clock; skipped: signalbox: .*ramp/)
  end

  it "wakes once the ramp window has passed" do
    started_ago(61)
    expect(beat).to eq(wakes)
  end

  it "stays quiet while the OS's level is unread and names the gap" do
    machine[:level] = 0
    expect(beat).to match(/\Aquiet: .*; skipped: signalbox: .*leaves the gap above the floor/)
  end

  it "keeps the plain quiet refusal when admission is off and the static cap holds" do
    allow(dispatching::AdmissionSwitch).to receive(:on?).and_return(false)
    expect(beat_with(admission_settings.except(:admitting))).to eq("quiet: nothing has become eligible by the clock")
  end
end
