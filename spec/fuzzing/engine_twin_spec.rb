require "spec_helper"
require "hecks/fuzzing"
require "hecks/corpus"
require_relative "../support/rust_conformance_helpers"
require_relative "../support/generated_rust"

# The gate of the engine seam: every corpus script under spec/corpus whose domain has a Cargo
# feature replays on the Ruby engine and on the kernel engine, and the two wire views agree on
# every field the QualityControl sweep compares (instances, events, refusals, queries, sagas,
# reactions, dry runs). The scripts the kernel cannot run yet are named, not skipped.
RSpec.describe "Hecks::Fuzzing::Engine twins (native binary)", :io do
  include_context "with the generated Rust tree"

  TWIN_ROOT = InMemoryDomain::ROOT
  TWIN_RUST_DIR = File.join(TWIN_ROOT, "rust")
  TWIN_FEATURES = Hecks::Corpus.rust_domains.to_h { |domain| [File.expand_path(domain.dir), domain.feature] }.freeze

  # The script's `domain`, or the corpus member its file is named for.
  def self.domain_of(path, fixture)
    return File.expand_path(fixture["domain"], TWIN_ROOT) if fixture["domain"]

    stem = File.basename(path, ".json")
    File.expand_path(Hecks::Corpus.members.find { |member| member.stem == stem }.path)
  end

  # Each script with its parsed fixture and domain directory.
  TWIN_SCRIPTS = Dir.glob(File.join(TWIN_ROOT, "spec/corpus/*.json")).map do |path|
    fixture = JSON.parse(File.read(path))
    [File.basename(path), fixture, domain_of(path, fixture)]
  end.freeze

  # The scripts whose domain has no Cargo feature, so no kernel binary runs them yet.
  KERNEL_CANNOT_RUN = %w[
    assurance.json change.json command_defaults.json command_list_argument.json console_settings.json
    copy_from_state.json directory.json expression.json governance.json identity.json list_field_shape.json
    multi_role.json onboarding.json order_deadline.json parent_visibility.json privacy.json translation.json
  ].freeze

  # The comparison helpers `Differential.diff` takes, with nothing tolerated up front.
  def differ
    Class.new do
      include RustConformanceHelpers

      def structural_skips = @structural_skips ||= Set.new
    end.new
  end

  def kernel_for(domain)
    feature = TWIN_FEATURES.fetch(domain)
    binary = Hecks::RustBuild::NativeBuild.build_rust_for(feature, TWIN_RUST_DIR)
    Hecks::Fuzzing::Engine::Kernel.new(binary || raise("rust/Cargo.toml has no #{feature} feature"))
  end

  # A kernel engine that drops the last step, so the two engines must disagree.
  def short_kernel(kernel)
    Class.new(SimpleDelegator) { def call(domain, steps, **) = __getobj__.call(domain, steps[0...-1], **) }.new(kernel)
  end

  it "names every corpus script whose domain the kernel cannot run yet" do
    expect(TWIN_SCRIPTS.reject { |_, _, domain| TWIN_FEATURES.key?(domain) }.map(&:first)).to eq(KERNEL_CANNOT_RUN)
  end

  TWIN_SCRIPTS.select { |_, _, domain| TWIN_FEATURES.key?(domain) }.each do |name, fixture, domain|
    it "#{name}: the Ruby and kernel engines give equal wire views" do
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
