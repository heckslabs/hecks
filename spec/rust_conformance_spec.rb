require "json"
require "open3"
require "hecks/fuzzing"
require "hecks/rust_build/kernel_input"
require_relative "support/rust_conformance_helpers"
require_relative "support/conformance_corpus"

# Runs each conformance fixture and full corpus script through a compiled Rust binary and holds
# every field of the result to the fixture's frozen `expect` — the same data
# spec/conformance_corpus_spec.rb holds the Ruby runtime to. Neither runtime is the oracle.
RSpec.describe "Rust conformance (native binary)", :io do
  include RustConformanceHelpers

  # Grouped by domain so each domain's binary builds once; switching cargo features forces a
  # partial rebuild.
  RUST_DIR = File.join(InMemoryDomain::ROOT, "rust")

  def build_rust_for(domain_feature) = super(domain_feature, RUST_DIR)

  # The full corpus scripts (banking, chess) ride along with the small fixtures: only a long
  # replay reaches divergences that need accumulated state.
  ConformanceCorpus.paths.sort_by { |path| [ConformanceCorpus.load(path).fetch("domain"), path] }.each do |script_path|
    # One example per script: splitting per field would repeat the cargo build and spawn.
    it "#{File.basename(script_path)}: instances, events, refusals, reactions, and sagas match the frozen expect" do
      fixture = ConformanceCorpus.load(script_path)
      steps = fixture.fetch("steps")
      expected = fixture.fetch("expect")
      feature = File.basename(fixture.fetch("domain")).downcase

      binary = build_rust_for(feature)
      skip "rust/Cargo.toml has no #{feature} feature — run hecks project_rust for it first" unless binary

      stdin = Hecks::RustBuild::KernelInput.json(File.join(InMemoryDomain::ROOT, fixture.fetch("domain")), steps)
      stdout, status = Open3.capture2(binary, stdin_data: stdin)
      expect(status).to be_success, "#{binary} exited #{status.exitstatus}:\n#{stdout}"

      rust_output = JSON.parse(stdout)
      strip_emitted_flags!(rust_output["instances"])
      strip_emitted_flags!(rust_output["queries"])
      strip_occurred_at!(rust_output["events"])

      # No tolerance: this corpus never asks a verb the manifest declares `generated: false`.
      %w[instances events refusals queries sagas dry_runs].each do |key|
        expect(rust_output[key]).to eq(expected[key]), "#{key} differs from the frozen expect"
      end

      # Rust's kernel cannot yet resolve cross-domain policies, which the corpus records as delivered.
      cross_domain = cross_domain_policy_names(rust_output)
      expect(rust_output.fetch("reactions"))
        .to eq(expected["reactions"].reject { |r| cross_domain.include?(r["policy"]) })
    end
  end

  # Rust refuses a query verb it never generated cleanly: TypeMismatch, exit 0, no panic.
  it "a named/declared query step whose shape this generator doesn't cover still refuses cleanly (not a " \
     "byte-for-byte comparison — Ruby answers this one for real)" do
    binary = build_rust_for("banking")
    skip "rust/Cargo.toml has no banking feature — run hecks project_rust for it first" unless binary

    uncovered = "Banking::Account.NoSuchQuery"
    stdout, status = Open3.capture2(
      binary,
      stdin_data: JSON.generate({ "steps" => [{ "query" => uncovered }] })
    )
    expect(status).to be_success, "#{binary} exited #{status.exitstatus}:\n#{stdout}"

    rust_output = JSON.parse(stdout)
    # The manifest declares no gap for this verb, so a divergence would be a fuzzer finding.
    expect(Hecks::Fuzzing::RustGapManifest.for_binary(binary).not_generated(uncovered)).to be_nil
    expect(rust_output["refusals"].size).to eq(1)
    expect(rust_output["refusals"][0]["verb"]).to eq(uncovered)
    expect(rust_output["refusals"][0]["error"])
      .to include(uncovered)
      .and include("is not generated for this domain")
    expect(rust_output["queries"]).to eq([])
  end
end
