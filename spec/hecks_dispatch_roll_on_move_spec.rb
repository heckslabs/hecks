require "spec_helper"
require_relative "support/machine_beats"

# A reading that moves a state rolls a fill before the beat's sweep does; no policy starts a roll
# from a reading that left the machine as it stood.
RSpec.describe "the fill that follows a movement of the machine" do
  include MachineBeats

  let(:hecks) { boot_hecks_in_memory(File.expand_path("../lib/hecks/hecks", __dir__)).registry.bluebook("Hecks") }
  let(:policies) { hecks.policies.select { |policy| policy.trigger_command.to_s.end_with?("Roll.Start", "Roll::Start", "Start") } }

  def kinds(*idles) = beat_through(idles.map { |idle| gauge(idle) })[:names].grep(/\A(Beaten|RollRequested)\z/)

  it "does not roll on the beat whose idle CPU crossed a mark: the load average alone decides" do
    expect(kinds(10.0)).to eq(%w[Beaten])
  end

  it "has no policy that starts a roll on every reading", :aggregate_failures do
    heard = policies.map { |policy| policy.on_event.to_s }

    expect(heard).not_to include("MachineRead", "Machine.MachineRead")
    expect(heard).to include("MachineSampled").or include("Machine.MachineSampled")
  end
end
