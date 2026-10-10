require "json"
require "open3"
require "hecks/cli/seed_semantics_corpus"
require "hecks/projector/exporter"
require_relative "support/conformance_corpus"

# Differential test of rust/host's mint audit (`reference_validate`, run over a stored value)
# against what the Ruby runtime answers on dispatch. Each `Write` step of a conformance fixture
# is a value; the fixture's frozen `expect` says whether dispatch accepted it and in what words
# it refused it, and the audit, handed the same value as a stored row (a slot a writer never
# sent is absent, not null), must accept or refuse it too. An invariant refusal must name the
# same rule; every other refusal (closed set, `admits:`, pattern, shape, a field left out, a
# name the value object does not declare) is worded exactly as dispatch words it. A command
# argument left out is the argument gate's, with no stored form, so it is not offered here.
RSpec.describe "Rust/Ruby stored-value parity (rust/host reference_validate)", :io do
  VALIDATE_HARNESS_HOST_DIR = File.expand_path("../rust/host", __dir__)
  VALIDATE_FIXTURE_DIR = File.expand_path("fixtures/rust_project", __dir__)
  VALIDATE_RULE_AFTER = /invariant violated — (.*) \(given /
  VALIDATE_RULE_OF_RUST = /violates its own invariant — (.*)\z/
  VALIDATE_ARGUMENT_GATE_KINDS = %w[AbsentArgument].freeze

  # One bluebook, the aggregate its `Write` steps store, and the corpus fixtures that write to it.
  VALIDATE_SUBJECTS = [
    {
      bluebook: "optional_nested_value_object_fixture/bluebook/optional_nested_value_object_fixture.bluebook",
      domain: "OptionalNestedValueObjectFixture", aggregate: "Layout",
      fixtures: %w[optional_nested_value_object_absent optional_nested_value_object_explicit]
    },
    {
      bluebook: "attribute_constraints_fixture/bluebook/attribute_constraints_fixture.bluebook",
      domain: "AttributeConstraintsFixture", aggregate: "Shelf",
      fixtures: %w[admits closed_set limit pattern required shape].map { |family| "attribute_constraints_#{family}" }
    }
  ].freeze

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

  def write_steps(source) = source.fetch("steps").select { |step| step.fetch("verb").end_with?(".Write") }

  # The record's identity: the key, written as a value object or, where a bare scalar stands in
  # for one, as itself.
  def key_of(args) = (args["key"].is_a?(Hash) ? args["key"]["value"] : args["key"]).to_s

  def value_id(name, args) = "#{name}: #{key_of(args)}"

  # A step is accepted when its record exists in the frozen expect; the refusals come in step order.
  def accepted?(source, step)
    record = "#{step.fetch("verb").delete_suffix(".Write")}##{key_of(step.fetch("args"))}"
    source.fetch("expect").fetch("instances").key?(record)
  end

  def refused_writes(source)
    source.fetch("expect").fetch("refusals").select { |refusal| refusal.fetch("verb").end_with?(".Write") }
  end

  def refuse_shared_keys!(name, writes)
    keys = writes.map { |step| key_of(step.fetch("args")) }
    return if keys.uniq.size == keys.size

    raise "#{name}: two writes share a key, so a refusal cannot be told from an accept"
  end

  # Each write step of a fixture with dispatch's answer: nil when accepted, the refusal otherwise.
  def dispatch_answers(name)
    source = fixture(name)
    writes = write_steps(source)
    refuse_shared_keys!(name, writes)
    refusals = refused_writes(source).each
    writes.map { |step| [step.fetch("args"), accepted?(source, step) ? nil : refusals.next] }
  end

  def exported_ir(subject)
    registry = Hecks::Runtime::Registry.new
    Hecks.with_registry(registry) do
      [InMemoryDomain::PERSISTENCE_PORT, InMemoryDomain::EXTRACTION_PORT, InMemoryDomain::MEMORY_ADAPTER,
       InMemoryDomain::PRISM_ADAPTER, File.join(VALIDATE_FIXTURE_DIR, subject.fetch(:bluebook))].each { |file| Kernel.load(file) }
    end
    Hecks::Projector::Exporter.call(registry).fetch(subject.fetch(:domain))
  end

  def rust_answers(subject, values)
    cases = values.map { |value| { "aggregate" => value[:aggregate], "id" => value[:id], "state" => value[:args] } }
    request = JSON.generate("ir" => exported_ir(subject), "cases" => cases)
    stdout, stderr, status = Open3.capture3(self.class.harness_binary, stdin_data: request)
    expect(status).to be_success, "validate_harness exited #{status.exitstatus}:\n#{stderr}"
    JSON.parse(stdout).fetch("results")
  end

  def argument_gate?(refusal) = refusal && VALIDATE_ARGUMENT_GATE_KINDS.include?(refusal.fetch("kind"))

  # One entry per stored value a subject's fixtures write: its id, dispatch's refusal (nil when
  # accepted) and the audit's answer.
  def subject_answers(subject)
    values = subject.fetch(:fixtures).flat_map do |name|
      dispatch_answers(name).map do |args, refusal|
        { id: value_id(name, args), fixture: name, args: args, refusal: refusal, aggregate: subject.fetch(:aggregate) }
      end
    end
    stored = values.reject { |value| argument_gate?(value[:refusal]) }
    stored.zip(rust_answers(subject, stored)).map { |value, answer| value.merge(answer: answer) }
  end

  def answers = VALIDATE_SUBJECTS.flat_map { |subject| subject_answers(subject) }

  # What the audit should say: the rule an invariant refusal names, or the refusal's own wording.
  # Dispatch names a command's own argument `Write.slugs`; a stored record has no command, so the
  # audit names the aggregate that holds it.
  def expected_say(value)
    return nil unless value[:refusal]

    error = value[:refusal].fetch("error")
    rule = error[VALIDATE_RULE_AFTER, 1]
    rule ? [:rule, rule] : [:wording, error.sub(/\AWrite\./, "#{value[:aggregate]}.")]
  end

  def audit_say(value)
    violation = value[:answer].fetch("violations", []).first
    return nil unless violation

    rule = violation[VALIDATE_RULE_OF_RUST, 1]
    rule ? [:rule, rule] : [:wording, violation.delete_prefix("#{value[:aggregate]}##{value[:id]}: ")]
  end

  def disagreements = answers.reject { |value| expected_say(value) == audit_say(value) }

  def refused_and_accepted_by_fixture
    answers.group_by { |value| value[:fixture] }.transform_values do |values|
      [values.count { |value| value[:refusal] }, values.count { |value| value[:refusal].nil? }]
    end
  end

  def optional_slot_rules
    values = answers.select { |value| value[:fixture].start_with?("optional_nested_value_object") }
    values.map { |value| value[:refusal]&.fetch("error")&.[](VALIDATE_RULE_AFTER, 1) }
  end

  it "accepts and refuses each stored value as dispatch does, naming the same rule or in the same words" do
    expect(disagreements.map { |value| [value[:id], value[:refusal], value[:answer]] }).to eq([])
  end

  it "covers, for every fixture, values the audit must refuse and values it must accept" do
    expect(refused_and_accepted_by_fixture.values.flatten.min).to be >= 1
  end

  it "holds every fixture of every subject" do
    expect(refused_and_accepted_by_fixture.size).to eq(VALIDATE_SUBJECTS.sum { |subject| subject.fetch(:fixtures).size })
  end

  it "covers more than five refused rules and more than five accepted values in the optional-slot fixtures" do
    rules = optional_slot_rules

    expect([rules.compact.uniq.size >= 5, rules.count(nil) >= 6]).to eq([true, true])
  end
end
