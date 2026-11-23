require "spec_helper"
require "hecks/hecks/adapters/machine_profiling"

# The capacity settings derived from a machine profile: the same profile gives the same defaults, a
# smaller machine gets smaller ones, and a derived value stays inside its declared bounds.
RSpec.describe Hecks::Adapters::MachineProfiling do
  include MachineProfiles

  let(:aggregate) { boot_hecks_in_memory.registry.bluebook("Hecks").aggregate("Profile") }
  let(:rows)      { described_class::Rows.of(aggregate) }

  def derive(setting, profile) = described_class::Derivation.value(setting, profile, rows)

  it "gives the same defaults for the same profile" do
    expect(described_class::Derivation.all(big, rows)).to eq(described_class::Derivation.all(big.dup, rows))
  end

  it "gives a smaller machine smaller defaults" do
    expect(derived_settings.map { |name| derive(name, small) < derive(name, big) }).to all(be(true))
  end

  it "derives heavy jobs as a third of the performance cores and spec workers as half" do
    expect([derive("heavy_jobs", big), derive("spec_workers", big)]).to eq([4, 6])
  end

  it "derives the load marks from the cores" do
    expect([derive("load_low", big), derive("load_high", big)]).to eq([16.0, 24.0])
  end

  it "derives residents from half the free memory over a resident's size, inside its bound" do
    expect([derive("residents", big), derive("residents", small)]).to eq([16, 7])
  end

  it "holds a derived value inside its bounds" do
    expect([derive("residents", tiny), derive("heavy_jobs", tiny), derive("spec_workers", big.merge(cores: 4))]).to eq([1, 1, 4])
  end

  it "reads the same rows from the bluebook file as from the booted bluebook" do
    expect(described_class::Rows.from_file).to eq(rows)
  end
end
