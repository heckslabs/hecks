require "json"
require "open3"
require "hecks/cli/seed_semantics_corpus"
require "hecks/projector/exporter"
require_relative "support/conformance_corpus"

# Differential test of rust/host's mint audit (`reference_validate`, run over a stored value) against
# the Ruby runtime's own door: each `Write` step of the optional-value-object conformance fixtures
# gives a value, Ruby accepts or refuses it on dispatch, and the Rust audit, handed the same value
# as a stored row (a slot a writer never sent is absent, not null), must accept or refuse it too and
# name the same rule. A rule that reads an unset slot must not turn into a lookup error.
RSpec.describe "Rust/Ruby stored-value parity (rust/host reference_validate)", :io do
  VALIDATE_HARNESS_HOST_DIR = File.expand_path("../rust/host", __dir__)
  VALIDATE_FIXTURE_BLUEBOOK = File.expand_path(
    "fixtures/rust_project/optional_nested_value_object_fixture/bluebook/optional_nested_value_object_fixture.bluebook", __dir__
  )
  VALIDATE_FIXTURES = %w[optional_nested_value_object_absent optional_nested_value_object_explicit].freeze
  VALIDATE_RULE_AFTER = /invariant violated — (.*) \(given /
  VALIDATE_RULE_OF_RUST = /violates its own invariant — (.*)\z/

  # Built once per suite run and memoized, failures included, as the expression spec builds its own.
  def self.harness_binary
    @harness_binary ||= build_harness
    raise @harness_binary if @harness_binary.is_a?(Exception)

    @harness_binary
  end

  def self.build_harness
    _stdout, stderr, status = Open3.capture3("cargo", "build", "--bin", "validate_harness", chdir: VALIDATE_HARNESS_HOST_DIR)
    binary = File.join(VALIDATE_HARNESS_HOST_DIR, "target", "debug", "validate_harness")
    return binary if status.success? && File.executable?(binary)

    RuntimeError.new("`cargo build --bin validate_harness` failed in #{VALIDATE_HARNESS_HOST_DIR}:\n#{stderr}")
  end

  def fixture(name) = ConformanceCorpus.load(File.join(InMemoryDomain::ROOT, "spec/corpus/rust_conformance/#{name}.json"))

  # The write steps of every fixture, each with the Ruby runtime's answer to it alone on a fresh
  # domain: nil when accepted, the refused rule's description otherwise.
  def written_values
    VALIDATE_FIXTURES.flat_map do |name|
      source = fixture(name)
      writes = source.fetch("steps").select { |step| step.fetch("verb").end_with?(".Write") }
      writes.map { |step| [name, step.fetch("args"), ruby_rule_refused(source, step)] }
    end
  end

  def ruby_rule_refused(source, step)
    one = { "domain" => source.fetch("domain"), "steps" => [step] }
    refusal = Hecks::CLI::SeedSemanticsCorpus.expectation_for(InMemoryDomain::ROOT, one, full: true).fetch("refusals").first
    refusal && refusal.fetch("error")[VALIDATE_RULE_AFTER, 1]
  end

  def exported_ir
    registry = Hecks::Runtime::Registry.new
    Hecks.with_registry(registry) do
      [InMemoryDomain::PERSISTENCE_PORT, InMemoryDomain::EXTRACTION_PORT, InMemoryDomain::MEMORY_ADAPTER,
       InMemoryDomain::PRISM_ADAPTER, VALIDATE_FIXTURE_BLUEBOOK].each { |file| Kernel.load(file) }
    end
    Hecks::Projector::Exporter.call(registry).fetch("OptionalNestedValueObjectFixture")
  end

  def rust_answers(values)
    cases = values.map { |name, args, _| { "aggregate" => "Layout", "id" => value_id(name, args), "state" => args } }
    request = JSON.generate("ir" => exported_ir, "cases" => cases)
    stdout, stderr, status = Open3.capture3(self.class.harness_binary, stdin_data: request)
    expect(status).to be_success, "validate_harness exited #{status.exitstatus}:\n#{stderr}"
    JSON.parse(stdout).fetch("results")
  end

  def value_id(name, args) = "#{name}: #{args.dig("key", "value")}"

  # Each value with Ruby's refused rule (nil when accepted) and the rule Rust's first violation names.
  def rules_by_value
    values = written_values
    values.zip(rust_answers(values)).map do |(name, args, ruby_rule), answer|
      rust_rule = answer.fetch("violations", []).first.to_s[VALIDATE_RULE_OF_RUST, 1]
      [value_id(name, args), ruby_rule, rust_rule, answer]
    end
  end

  it "accepts and refuses each stored value as the Ruby runtime does, naming the same rule" do
    disagreements = rules_by_value.reject { |_, ruby_rule, rust_rule, _| ruby_rule == rust_rule }

    expect(disagreements.map { |id, ruby_rule, _, answer| [id, ruby_rule, answer] }).to eq([])
  end

  it "covers refused values and more than five accepted ones, absent slots among them" do
    rules = rules_by_value.map { |_, ruby_rule, _, _| ruby_rule }

    expect([rules.compact.uniq.size >= 5, rules.count(nil) >= 6]).to eq([true, true])
  end
end
