require "json"
require "open3"
require "hecks/fuzzing"
require_relative "support/rust_conformance_helpers"

# Runs each rust_conformance fixture and full corpus script through a compiled Rust binary
# and compares every field of the result with Ruby's replay.
RSpec.describe "Rust conformance (native binary)", :io do
  include RustConformanceHelpers

  # Grouped by domain so each domain's binary builds once; switching cargo features forces a
  # partial rebuild.
  RUST_CONFORMANCE_FIXTURES = Dir.glob(File.join(InMemoryDomain::ROOT, "spec/corpus/rust_conformance/*.json"))
                                 .sort_by { |path| [JSON.parse(File.read(path)).fetch("domain"), path] }
  RUST_DIR = File.join(InMemoryDomain::ROOT, "rust")

  def build_rust_for(domain_feature) = super(domain_feature, RUST_DIR)

  # Full corpus scripts held to the same byte-for-byte bar as the small fixtures; only a long
  # replay reaches divergences that need accumulated state. Keyed by corpus file, valued by domain.
  FULL_CORPUS_MEMBERS = {
    "spec/corpus/banking.json" => "examples/banking",
    "spec/corpus/chess.json"   => "examples/chess"
  }.freeze

  full_corpus_cases = FULL_CORPUS_MEMBERS.map do |corpus_path, domain|
    [corpus_path, domain, File.join(InMemoryDomain::ROOT, corpus_path)]
  end
  fixture_cases = RUST_CONFORMANCE_FIXTURES.map do |fixture_path|
    [File.basename(fixture_path), JSON.parse(File.read(fixture_path)).fetch("domain"), fixture_path]
  end

  (fixture_cases + full_corpus_cases).each do |label, domain, script_path|
    # One example per script: splitting per field would repeat the cargo build and spawn.
    # rubocop:disable-next RSpec/ExampleLength
    it "#{label}: instances, events, refusals, reactions, and sagas match Ruby exactly" do
      steps = JSON.parse(File.read(script_path)).fetch("steps")

      binary = build_rust_for(File.basename(domain).downcase)
      skip "rust/Cargo.toml has no #{File.basename(domain).downcase} feature — run hecks project_rust for it first" unless binary

      ruby_result = Hecks::Fuzzing::Replay.call(domain, steps)
      ruby_instances = ruby_result[:instances].transform_values { |state| JSON.parse(JSON.generate(state)) }
      ruby_events = JSON.parse(JSON.generate(ruby_result[:events]))
      ruby_refusals = ruby_result[:refusals].map do |r|
        { "verb" => r[:verb].to_s, "error" => r[:error], "kind" => r[:kind]&.split("::")&.last }
      end
      # instances_at is Replay's per-query snapshot for the property harness; Rust has none.
      ruby_queries = JSON.parse(JSON.generate(ruby_result[:queries].map { |q| q.except(:instances_at) }))
      ruby_sagas = JSON.parse(JSON.generate(ruby_result[:sagas]))

      stdout, status = Open3.capture2(binary, stdin_data: JSON.generate({ "steps" => steps }))
      expect(status).to be_success, "#{binary} exited #{status.exitstatus}:\n#{stdout}"

      rust_output = JSON.parse(stdout)
      strip_emitted_flags!(rust_output["instances"])
      strip_emitted_flags!(rust_output["queries"])
      strip_occurred_at!(rust_output["events"])

      expect(rust_output["instances"]).to eq(ruby_instances)
      expect(rust_output["events"]).to eq(ruby_events)
      # No tolerance: this corpus never asks a verb the manifest declares `generated: false`.
      expect(rust_output["refusals"]).to eq(ruby_refusals)
      expect(rust_output["queries"]).to eq(ruby_queries)
      expect(rust_output["sagas"]).to eq(ruby_sagas)
      expect(rust_output["dry_runs"]).to eq(JSON.parse(JSON.generate(ruby_result[:dry_runs])))

      cross_domain = cross_domain_policy_names(rust_output)
      ruby_reactions = JSON.parse(JSON.generate(ruby_result[:reactions]))
                           .reject { |r| cross_domain.include?(r["policy"]) }
      expect(rust_output.fetch("reactions")).to eq(ruby_reactions)
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
