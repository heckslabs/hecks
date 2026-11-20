require "spec_helper"
require "hecks/fuzzing"
require "hecks/corpus"
require_relative "../support/rust_conformance_helpers"

# The gate of the engine seam: every corpus script under spec/corpus replays on the Ruby engine
# and on the kernel engine, and the two wire views agree on every field the QualityControl
# sweep compares (instances, events, refusals, queries, sagas, reactions, dry runs). A script
# whose domain has no Cargo feature is skipped by name: the kernel cannot run it yet.
RSpec.describe "Hecks::Fuzzing::Engine twins (native binary)", :io do
  TWIN_ROOT = InMemoryDomain::ROOT
  TWIN_RUST_DIR = File.join(TWIN_ROOT, "rust")
  TWIN_RUST_DOMAINS = Hecks::Corpus.rust_domains.to_h { |domain| [File.expand_path(domain.dir), domain.feature] }.freeze

  # The comparison helpers `Differential.diff` takes, with nothing tolerated up front.
  def differ
    Class.new do
      include RustConformanceHelpers

      def structural_skips = @structural_skips ||= Set.new
    end.new
  end

  # The script's `domain`, or the corpus member its file is named for.
  def domain_of(path, fixture)
    return File.expand_path(fixture["domain"], TWIN_ROOT) if fixture["domain"]

    stem = File.basename(path, ".json")
    File.expand_path(Hecks::Corpus.members.find { |member| member.stem == stem }.path)
  end

  # A kernel engine that drops the last step, so the two engines must disagree.
  def short_kernel(kernel)
    Class.new(SimpleDelegator) { def call(domain, steps, **) = __getobj__.call(domain, steps[0...-1], **) }.new(kernel)
  end

  def kernel_for(domain)
    feature = TWIN_RUST_DOMAINS[domain] or skip("#{domain} has no Cargo feature: the kernel cannot run it")
    binary = Hecks::RustBuild::NativeBuild.build_rust_for(feature, TWIN_RUST_DIR)
    Hecks::Fuzzing::Engine::Kernel.new(binary || skip("rust/Cargo.toml has no #{feature} feature"))
  end

  Dir.glob(File.join(TWIN_ROOT, "spec/corpus/*.json")).each do |path|
    it "#{File.basename(path)}: the Ruby and kernel engines give equal wire views" do
      fixture = JSON.parse(File.read(path))
      domain = domain_of(path, fixture)
      divergences = Hecks::Fuzzing::Engine.divergences(differ, domain, fixture.fetch("steps"),
                                                       kernel: kernel_for(domain), identity: fixture["identity"])
      expect(divergences).to be_empty, JSON.pretty_generate(divergences)
    end
  end

  it "finds the divergence when the kernel misses a step" do
    domain = File.join(TWIN_ROOT, "examples/chess")
    steps = JSON.parse(File.read(File.join(TWIN_ROOT, "spec/corpus/chess.json"))).fetch("steps")
    divergences = Hecks::Fuzzing::Engine.divergences(differ, domain, steps, kernel: short_kernel(kernel_for(domain)))
    expect(divergences.map { |divergence| divergence[:field] }).to include("events")
  end
end
