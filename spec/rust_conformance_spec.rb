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

  RUST_CONFORMANCE_UNCOVERED_QUERY = "Banking::Account.NoSuchQuery".freeze

  # The fixture domain's compiled binary, skipping the example when its feature is not built.
  def binary_for(fixture)
    feature = File.basename(fixture.fetch("domain")).downcase
    build_rust_for(feature) || skip("rust/Cargo.toml has no #{feature} feature — run hecks build.project_rust! for it first")
  end

  def kernel_stdout(binary, fixture)
    stdin = Hecks::RustBuild::KernelInput.json(File.join(InMemoryDomain::ROOT, fixture.fetch("domain")), fixture.fetch("steps"),
                                               identity: fixture["identity"])
    stdout, status = Open3.capture2(binary, stdin_data: stdin)
    expect(status).to be_success, "#{binary} exited #{status.exitstatus}:\n#{stdout}"
    stdout
  end

  def stripped_rust_output(stdout)
    JSON.parse(stdout).tap do |rust_output|
      strip_emitted_flags!(rust_output["instances"])
      strip_emitted_flags!(rust_output["queries"])
      strip_occurred_at!(rust_output["events"])
      strip_wire_only_dry_run_fields!(rust_output["dry_runs"])
    end
  end

  # What the host's preview envelope reads from a refused dry run, which the frozen `expect` does
  # not carry: the neutral corpus holds `verb`, `ok` and `error`.
  def strip_wire_only_dry_run_fields!(dry_runs)
    Array(dry_runs).each { |dry| %w[kind stage refusal refusals].each { |key| dry.delete(key) } }
  end

  # A fixture that sets `rust_echoes_absent_slots_as_null` sends optional slots of a nested value
  # object left out. Ruby keeps them absent; a Rust record holds each as an `Option`, so it echoes
  # them as null. Both sides are compared with null-valued keys dropped, and nothing else.
  def without_null_slots(value)
    case value
    when Hash then value.compact.transform_values { |v| without_null_slots(v) }
    when Array then value.map { |v| without_null_slots(v) }
    when String then value.gsub(/,"[^"]*":null/, "").gsub(/\{"[^"]*":null,/, "{").gsub(/\{"[^"]*":null\}/, "{}")
    else value
    end
  end

  # The two sides to hold equal: untouched, unless the fixture says Rust echoes absent slots as
  # null.
  def comparable_pair(rust_output, expected, fixture)
    return [rust_output, expected] unless fixture["rust_echoes_absent_slots_as_null"]

    [without_null_slots(rust_output), without_null_slots(expected)]
  end

  def expect_fields_match(rust_output, expected)
    # No tolerance: this corpus never asks a verb the manifest declares `generated: false`.
    %w[instances events refusals queries sagas dry_runs].each do |key|
      expect(rust_output[key]).to eq(expected[key]), "#{key} differs from the frozen expect"
    end
    expect_validations_match(rust_output, expected)
    # Rust's kernel cannot yet resolve cross-domain policies, which the corpus records as delivered.
    cross_domain = cross_domain_policy_names(rust_output)
    expect(rust_output.fetch("reactions")).to eq(expected["reactions"].reject { |r| cross_domain.include?(r["policy"]) })
  end

  # Only a fixture with a `validate` step freezes the key.
  def expect_validations_match(rust_output, expected)
    expect(rust_output.fetch("validations", [])).to eq(expected.fetch("validations", [])),
                                                    "validations differ from the frozen expect"
  end

  def banking_binary
    build_rust_for("banking") || skip("rust/Cargo.toml has no banking feature — run hecks build.project_rust! for it first")
  end

  def uncovered_query_output(binary)
    stdin = JSON.generate({ "steps" => [{ "query" => RUST_CONFORMANCE_UNCOVERED_QUERY }] })
    stdout, status = Open3.capture2(binary, stdin_data: stdin)
    expect(status).to be_success, "#{binary} exited #{status.exitstatus}:\n#{stdout}"
    JSON.parse(stdout)
  end

  # The full corpus scripts (banking, chess) ride along with the small fixtures: only a long
  # replay reaches divergences that need accumulated state.
  ConformanceCorpus.paths.sort_by { |path| [ConformanceCorpus.load(path).fetch("domain"), path] }.each do |script_path|
    # One example per script: splitting per field would repeat the cargo build and spawn.
    it "#{File.basename(script_path)}: instances, events, refusals, reactions, and sagas match the frozen expect",
       :aggregate_failures do
      fixture = ConformanceCorpus.load(script_path)
      rust_output = stripped_rust_output(kernel_stdout(binary_for(fixture), fixture))

      expect_fields_match(*comparable_pair(rust_output, fixture.fetch("expect"), fixture))
    end
  end

  # Rust refuses a query verb it never generated cleanly: TypeMismatch, exit 0, no panic.
  it "refuses a query step whose shape this generator doesn't cover, once, naming the verb", :aggregate_failures do
    refusals = uncovered_query_output(banking_binary)["refusals"]

    expect(refusals.size).to eq(1)
    expect(refusals[0]["verb"]).to eq(RUST_CONFORMANCE_UNCOVERED_QUERY)
  end

  it "says the uncovered query is not generated for this domain (not a byte-for-byte comparison — Ruby answers it)" do
    refusal = uncovered_query_output(banking_binary)["refusals"][0]

    expect(refusal["error"]).to include(RUST_CONFORMANCE_UNCOVERED_QUERY).and include("is not generated for this domain")
  end

  it "answers no query rows for the uncovered query, and the manifest declares no gap for it", :aggregate_failures do
    binary = banking_binary

    # The manifest declares no gap for this verb, so a divergence would be a fuzzer finding.
    gaps = Hecks::Fuzzing::RustGapManifest.for_binary(binary, rust_dir: RUST_DIR)
    expect(gaps.not_generated(RUST_CONFORMANCE_UNCOVERED_QUERY)).to be_nil
    expect(uncovered_query_output(binary)["queries"]).to eq([])
  end

  # bluebook.bluebook's commands declare `role "Language"`, the role the Ruby judge states when it
  # loads a bluebook through them (ADR 0216). The generated `meta` crate runs the same commands, so
  # its kernel answers each caller as Ruby does: the stated role runs, the caller who stated no role
  # is refused, and a step with no caller is the process's own and runs.
  LANGUAGE_ROLE_STEPS = [
    { "verb" => "Bluebook::Bluebook.Declare", "role" => "Language", "args" => { "name" => { "value" => "Stated" } } },
    { "verb" => "Bluebook::Bluebook.Declare", "role" => "Anonymous", "args" => { "name" => { "value" => "Unstated" } } },
    { "verb" => "Bluebook::Bluebook.Declare", "args" => { "name" => { "value" => "Internal" } } }
  ].freeze

  LANGUAGE_UNSTATED_REFUSAL = { "verb" => "Bluebook::Bluebook.Declare", "kind" => "Unauthorized",
                                "error" => "Declare refused — role: Language, and the caller stated no role" }.freeze

  def meta_output
    binary = build_rust_for("meta") || skip("rust/Cargo.toml has no meta feature")
    stdout, status = Open3.capture2(binary, stdin_data: JSON.generate({ "steps" => LANGUAGE_ROLE_STEPS }))
    expect(status).to be_success, "#{binary} exited #{status.exitstatus}:\n#{stdout}"
    JSON.parse(stdout)
  end

  # The same steps dispatched into the Ruby runtime's bluebook.bluebook, each as its step's caller.
  def ruby_language_refusals
    runtime = Hecks::Bluebook::MetaValidator.fresh_runtime
    LANGUAGE_ROLE_STEPS.filter_map do |step|
      as_step_caller(step) { runtime.dispatch(step["verb"], with: { name: { value: step.dig("args", "name", "value") } }) }
      nil
    rescue Hecks::Runtime::Unauthorized => e
      { "verb" => step["verb"], "kind" => "Unauthorized", "error" => e.message }
    end
  end

  def as_step_caller(step, &)
    return Hecks::Runtime::Caller.without(&) unless step["role"]

    Hecks::Runtime::Caller.as(role: step["role"], &)
  end

  it "refuses bluebook.bluebook's Declare to a caller who stated no role, in the generated meta crate" do
    expect(meta_output["refusals"]).to eq([LANGUAGE_UNSTATED_REFUSAL])
  end

  it "runs bluebook.bluebook's Declare as the Language role and as the process's own step, in the meta crate" do
    expect(meta_output["instances"].keys).to contain_exactly("Bluebook::Bluebook#Stated", "Bluebook::Bluebook#Internal")
  end

  it "answers bluebook.bluebook's callers in the Ruby runtime as the meta crate does" do
    mode = Hecks::Runtime::RoleShadow.mode
    Hecks::Runtime::RoleShadow.install(:enforce)
    expect(ruby_language_refusals).to eq([LANGUAGE_UNSTATED_REFUSAL])
  ensure
    Hecks::Runtime::RoleShadow.install(mode)
  end
end
