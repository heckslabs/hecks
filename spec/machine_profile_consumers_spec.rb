require "spec_helper"
require "tmpdir"
require_relative "support/machine_profiles"
require "hecks/hecks/adapters/codebase/heavy_slots"
require "hecks/hecks/adapters/machine_sampling/marks"

# The settings that read the machine's profile: a machine's own figures stand where the owner
# declares none, and a declared setting is respected until it is removed.
RSpec.describe "the capacity settings derived from the machine" do
  include MachineProfiles

  let(:profiling) { Hecks::Adapters::MachineProfiling }
  let(:marks)     { Hecks::Adapters::MachineSampling::Marks }
  let(:slots)     { Hecks::Adapters::Codebase::HeavySlots }
  let(:root)      { Dir.mktmpdir("derived") }

  after { FileUtils.rm_rf(root) }

  it "gives a smaller machine fewer heavy-job places" do
    allow(profiling).to receive(:standing).and_return(small)
    expect(slots.declared_cap(root)).to eq(1)
  end

  it "gives a larger machine more heavy-job places" do
    allow(profiling).to receive(:standing).and_return(big)
    expect(slots.declared_cap(root)).to eq(4)
  end

  it "derives the load marks from the cores when the world declares none" do
    allow(profiling).to receive(:standing).and_return(small)
    expect(marks.laid_over({}).values_at(:load_low, :load_high)).to eq([8.0, 12.0])
  end

  it "respects a load mark the owner declares" do
    allow(profiling).to receive(:standing).and_return(small)
    expect(marks.laid_over({ load_high: 10.0 })[:load_high]).to eq(10.0)
  end

  it "respects a heavy-jobs cap the world declares" do
    allow(profiling).to receive(:standing).and_return(big)
    allow(Hecks::RustBuild::WorldRows).to receive(:row).with(root, "heavy_jobs").and_return({ cap: 2 })
    expect(slots.declared_cap(root)).to eq(2)
  end
end
