# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "hecks/hecks/adapters/codebase/spec_workers"

# A parallel spec run takes at most the Tickets world's `spec_workers` cap of workers, and never
# more than the machine has cores, so one run cannot take the whole machine.
RSpec.describe Hecks::Adapters::Codebase::SpecWorkers do
  let(:root) { Dir.mktmpdir("spec-workers") }

  after { FileUtils.rm_rf(root) }

  it "holds a 12-core machine to half its cores by default" do
    expect(described_class.count(root, cores: 12, base: {})).to eq(6)
  end

  it "gives a machine with fewer cores than the cap every core" do
    expect(described_class.count(root, cores: 4, base: {})).to eq(4)
  end

  it "gives at least one worker" do
    expect(described_class.count(root, cores: 0, base: {})).to eq(1)
  end

  it "reads its cap from the Tickets world's spec_workers line" do
    allow(Hecks::RustBuild::WorldRows).to receive(:row).with(root, "spec_workers").and_return({ max: 2 })
    expect(described_class.count(root, cores: 12, base: {})).to eq(2)
  end

  it "is held to the worker count a parent already set" do
    expect(described_class.count(root, cores: 12, base: { "PARALLEL_PROCESSOR_COUNT" => "2" })).to eq(2)
  end

  it "ignores a worker count that is not a positive number" do
    expect(described_class.count(root, cores: 12, base: { "PARALLEL_PROCESSOR_COUNT" => "x" })).to eq(6)
  end

  it "is the checkout's committed world's figure, 6" do
    committed = Hecks::Adapters::FolderOverlay.committed_only { described_class.max_of(File.expand_path("..", __dir__)) }
    expect(committed).to eq(6)
  end
end
