require "spec_helper"
require_relative "support/machine_beats"

# A fill that starts nothing for a quarter of an hour while work waits and the preview shows room
# is said once, with its reason, and said to be over when a start happens.
RSpec.describe "a stalled fill" do
  include MachineBeats

  Looks = Struct.new(:answers) do
    def look(**)
      answer = answers.shift
      raise Hecks::Adapters::ConsoleCapture::Failure, "flowing: a start happened" unless answer

      answer
    end
  end

  let(:paused) do
    { reason: { value: "held by pause: 324 waits (paused by load)" },
      reading: { value: "load 22.8 from roundhouse against load_high 22" },
      held_minutes: { value: 41 }, governed_by: { value: "load_high in machine_marks; dispatch_roll_forward" } }
  end

  def beats_with(*answers)
    looks = Looks.new(answers)
    registry = boot_hecks_in_memory(File.expand_path("../lib/hecks/hecks", __dir__)).registry
    lookup = ->(port, _asked) { port.to_s == "FillWatching" ? looks : CountedRolls.new([]) }
    Hecks::Runtime::AdapterLookup.standing_in(lookup) do
      answers.size.times { |index| beat(registry, index) }
    end
    registry.event_log.map(&:name).grep(/\AFill(Stalled|Cleared)\z/)
  end

  it "raises FillStalled once for a paused fill with room" do
    expect(beats_with(paused, paused)).to eq(%w[FillStalled])
  end

  it "clears it when a start happens" do
    expect(beats_with(paused, nil)).to eq(%w[FillStalled FillCleared])
  end

  it "raises it again when the fill stalls anew" do
    expect(beats_with(paused, nil, paused)).to eq(%w[FillStalled FillCleared FillStalled])
  end
end
