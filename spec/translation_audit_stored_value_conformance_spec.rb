require "hecks"
require "hecks/ports/persistence/plugins/era"
require_relative "support/stored_value_corpus"

# Holds the Ruby mint audit's Layer 1 (`Translation::Audit.layer_one!`) to the answers the
# conformance corpus froze for dispatch, over the same stored values the Rust audit is held to by
# spec/rust_host_reference_validate_conformance_spec.rb, so the two audits agree: a required field
# stored nil, a name the value object does not declare, a closed set, `admits:`, a pattern or an
# invariant is refused, and in the same words.
RSpec.describe "Translation::Audit Layer 1 against the stored-value corpus" do
  include StoredValueCorpus

  def aggregate_of(subject)
    bluebook = subject_registry(subject).bluebooks.fetch(subject.fetch(:domain))
    bluebook.aggregates.find { |aggregate| aggregate.name.to_s == subject.fetch(:aggregate) }
  end

  def audit_violation(aggregate, value)
    violations = []
    Hecks::Translation::Audit.layer_one!(violations, aggregate, { value[:id] => value[:args] })
    violations.first
  end

  def subject_answers(subject)
    aggregate = aggregate_of(subject)
    stored_values(subject).map { |value| value.merge(violation: audit_violation(aggregate, value)) }
  end

  def answers = StoredValueCorpus::SUBJECTS.flat_map { |subject| subject_answers(subject) }

  def audit_say(value)
    return nil unless value[:violation]

    words = value[:violation].delete_prefix("#{value[:aggregate]}##{value[:id]}: ")
    rule = words[StoredValueCorpus::RULE_AFTER, 1]
    rule ? [:rule, rule] : [:wording, words]
  end

  def disagreements = answers.reject { |value| expected_say(value) == audit_say(value) }

  it "accepts and refuses each stored value as dispatch does, naming the same rule or in the same words" do
    expect(disagreements.map { |value| [value[:id], value[:refusal], value[:violation]] }).to eq([])
  end

  it "refuses a required field stored nil, as the Rust audit does" do
    refused = answers.map { |value| value[:violation] }.compact

    expect(refused).to include(a_string_matching(/expects String, got nil\z/))
  end
end
