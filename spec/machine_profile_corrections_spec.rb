require "spec_helper"
require_relative "support/machine_profiles"
require "hecks/hecks/adapters/machine_profiling"

# A kept turn is a correction to the derived default for one machine: it scales the formula's value
# and the result still stays inside the declared bounds.
RSpec.describe Hecks::Adapters::MachineProfiling do
  include MachineProfiles

  let(:rows) { described_class::Rows.from_file }

  def derive(setting, profile, corrections = {}) = described_class::Derivation.value(setting, profile, rows, corrections)

  it "scales the derived value by a kept correction" do
    expect(derive("heavy_jobs", big, "heavy_jobs" => 0.5)).to eq(2)
  end

  it "holds a corrected value inside its bounds" do
    expect([derive("heavy_jobs", big, "heavy_jobs" => 4.0), derive("heavy_jobs", small, "heavy_jobs" => 0.25)]).to eq([8, 1])
  end

  it "ignores a correction for another setting" do
    expect(derive("spec_workers", big, "heavy_jobs" => 0.5)).to eq(derive("spec_workers", big))
  end

  it "leaves a machine with no corrections at its derived values" do
    expect(derive("heavy_jobs", big, {})).to eq(derive("heavy_jobs", big))
  end
end
