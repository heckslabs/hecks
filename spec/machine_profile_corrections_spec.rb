require "spec_helper"
require_relative "support/machine_profiles"
require "hecks/hecks/adapters/machine_profiling"

# A kept turn is a correction to the derived default for this machine: it moves the value, and the
# value still stays inside its declared bounds. A machine with no kept turn starts from the
# derivation.
RSpec.describe Hecks::Adapters::MachineProfiling do
  include MachineProfiles

  let(:aggregate) { boot_hecks_in_memory.registry.bluebook("Hecks").aggregate("Profile") }
  let(:rows)      { described_class::Rows.of(aggregate) }

  def derive(setting, profile, factors = {})
    described_class::Derivation.value(setting, profile, rows.merge(corrections: factors))
  end

  it "moves a derived value by its kept correction" do
    expect(derive("heavy_jobs", big, "heavy_jobs" => 1.5)).to eq(6)
  end

  it "holds a corrected value inside its bound" do
    expect(derive("heavy_jobs", big, "heavy_jobs" => 4.0)).to eq(8)
  end

  it "leaves a setting with no correction as derived" do
    expect(derive("spec_workers", big, "heavy_jobs" => 1.5)).to eq(6)
  end

  it "starts a machine with no kept turn from its derived values" do
    expect(derive("heavy_jobs", small)).to eq(1)
  end

  it "declares a turn aggregate keyed by the machine's fingerprint" do
    turn = boot_hecks_in_memory.registry.bluebook("Hecks").aggregate("Turn")
    expect(turn.commands.map(&:hecks_name)).to eq(%w[Take Keep Revert])
  end
end
