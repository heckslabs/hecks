require "json"
require "open3"
require "hecks/hecks/adapters/codebase/test_suite/semantics_seeding"
require "hecks/projector/exporter"
require_relative "support/stored_value_corpus"

# Differential test of rust/host's mint audit (`reference_validate`, run over a stored value)
# against what the Ruby runtime answers on dispatch. Each stored value of `StoredValueCorpus`
# carries its fixture's frozen answer, and the audit, handed the same value as a stored row, must
# accept or refuse it too. An invariant refusal must name the same rule; every other refusal
# (closed set, `admits:`, pattern, shape, a field left out, a name the value object does not
# declare) is worded exactly as dispatch words it. The Ruby `Translation::Audit` is held to the
# same answers by spec/translation_audit_stored_value_conformance_spec.rb.
RSpec.describe "Rust/Ruby stored-value parity (rust/host reference_validate)", :io do
  include StoredValueCorpus

  VALIDATE_HARNESS_HOST_DIR = File.expand_path("../rust/host", __dir__)
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

  def exported_ir(subject)
    Hecks::Projector::Exporter.call(subject_registry(subject)).fetch(subject.fetch(:domain))
  end

  def rust_answers(subject, values)
    cases = values.map { |value| { "aggregate" => value[:aggregate], "id" => value[:id], "state" => value[:args] } }
    request = JSON.generate("ir" => exported_ir(subject), "cases" => cases)
    stdout, stderr, status = Open3.capture3(self.class.harness_binary, stdin_data: request)
    expect(status).to be_success, "validate_harness exited #{status.exitstatus}:\n#{stderr}"
    JSON.parse(stdout).fetch("results")
  end

  # One entry per stored value a subject's fixtures write: its id, dispatch's refusal (nil when
  # accepted) and the audit's answer.
  def subject_answers(subject)
    stored = stored_values(subject)
    stored.zip(rust_answers(subject, stored)).map { |value, answer| value.merge(answer: answer) }
  end

  def answers = StoredValueCorpus::SUBJECTS.flat_map { |subject| subject_answers(subject) }

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
    values.map { |value| value[:refusal]&.fetch("error")&.[](StoredValueCorpus::RULE_AFTER, 1) }
  end

  it "accepts and refuses each stored value as dispatch does, naming the same rule or in the same words" do
    expect(disagreements.map { |value| [value[:id], value[:refusal], value[:answer]] }).to eq([])
  end

  it "covers, for every fixture, values the audit must refuse and values it must accept" do
    expect(refused_and_accepted_by_fixture.values.flatten.min).to be >= 1
  end

  it "holds every fixture of every subject" do
    fixtures = StoredValueCorpus::SUBJECTS.sum { |subject| subject.fetch(:fixtures).size }

    expect(refused_and_accepted_by_fixture.size).to eq(fixtures)
  end

  it "covers more than five refused rules and more than five accepted values in the optional-slot fixtures" do
    rules = optional_slot_rules

    expect([rules.compact.uniq.size >= 5, rules.count(nil) >= 6]).to eq([true, true])
  end
end
