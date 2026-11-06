require "spec_helper"
require "hecks/fuzzing"
require "hecks/fuzzing/engine"
require_relative "../support/rust_conformance_helpers"
require_relative "../support/engine_twin_corpus"

# The twin of the engine seam: each `spec/corpus/*.json` the kernel can run is played through
# `RubyEngine` and `KernelEngine`, and their wire views are compared field by field.
#
# The kernel under test is the `pizzas` build, so only a script for that domain runs; every other
# file is listed as skipped, named with its reason. A kernel session carries instances, events,
# refusals (verb only) and dry runs; it carries no queries and no sagas, so those two fields are
# not compared, and a step of another kind is left out of the kernel's run and named in
# `:uncarried`.
RSpec.describe Hecks::Fuzzing::Engine, :io do
  include RustConformanceHelpers

  def kernel_engine
    described_class::KernelEngine.new(binary: build_rust_for(EngineTwinCorpus::FEATURE, Hecks::RustBuild.rust_dir))
  end

  def wire_view(engine, path) = described_class.wire_view(EngineTwinCorpus.history_through(engine, path))

  def differing_fields(path)
    ruby, kernel = [described_class::RubyEngine.new, kernel_engine].map { |engine| wire_view(engine, path) }
    described_class::CARRIED.reject { |field| kernel[field] == ruby[field] }
  end

  EngineTwinCorpus.paths.each do |path|
    it("#{File.basename(path)}: both engines give equal wire views") do
      reason = EngineTwinCorpus.skip_reason(path)
      skip reason if reason
      expect(differing_fields(path)).to eq([])
    end
  end

  it "compares non-empty views: pizzas.json has events, refusals and instances" do
    view = wire_view(kernel_engine, EngineTwinCorpus.pizzas_path)

    expect(view.values_at(:events, :refusals, :instances)).to all(satisfy { |rows| !rows.empty? })
  end

  it "names the steps the session cannot carry" do
    history = EngineTwinCorpus.history_through(kernel_engine, EngineTwinCorpus.pizzas_path)

    expect(history[:uncarried].uniq).to eq(["query"])
  end
end
