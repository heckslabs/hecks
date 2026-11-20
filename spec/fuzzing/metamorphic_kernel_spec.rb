require "spec_helper"
require "hecks/corpus"
require "hecks/fuzzing/properties/metamorphic"
require "hecks/rust_build/native_build"

# The gate of slice 6 of docs/plans/simulation-tests.md on the real kernel: the pizzas kernel,
# served over the host protocol and given spec/corpus/pizzas.json, passes every metamorphic
# property, and each planted engine fault fails the properties it names. Needs a cargo build.
RSpec.describe "Hecks::Fuzzing::Properties::Metamorphic on the pizzas kernel (native binary)", :io do
  METAMORPHIC = Hecks::Fuzzing::Properties::Metamorphic
  METAMORPHIC_ROOT = File.expand_path("../..", __dir__)

  let(:steps) { JSON.parse(File.read(File.join(METAMORPHIC_ROOT, "spec/corpus/pizzas.json"))).fetch("steps") }
  let(:domain) { File.expand_path(Hecks::Corpus.rust_domains.find { |member| member.feature == "pizzas" }.dir) }
  let(:binary) { Hecks::RustBuild::NativeBuild.build_rust_for("pizzas", File.join(METAMORPHIC_ROOT, "rust")) }

  # The property verdicts on the kernel, with `fault` planted when given.
  def verdicts(fault = nil)
    probe = METAMORPHIC::Probe.for(binary, domain, wrap: fault && METAMORPHIC::Faults.wrap(fault))
    METAMORPHIC.check(probe, steps).tap { probe.close }
  end

  it "passes every property on the honest kernel" do
    expect(verdicts).to eq(METAMORPHIC::NAMES.to_h { |name| [name, true] })
  end

  METAMORPHIC::Faults::CATALOG.each_key do |fault|
    it "fails #{METAMORPHIC::Faults.trips(fault).join(" and ")} when #{fault} is planted" do
      failed = verdicts(fault).reject { |_name, verdict| verdict == true }.keys
      expect(METAMORPHIC::Faults.trips(fault) - failed).to be_empty
    end
  end
end
