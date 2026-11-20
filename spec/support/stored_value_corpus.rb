require "json"
require_relative "conformance_corpus"

# The stored values the conformance corpus writes, each with dispatch's frozen answer, for the
# mint audits to be held to: the Rust audit (spec/rust_host_reference_validate_conformance_spec.rb)
# and the Ruby `Translation::Audit` (spec/translation_audit_stored_value_conformance_spec.rb).
# Each `Write` step of a fixture is a value; a slot a writer never sent is absent, not null. A
# command argument left out is the argument gate's, with no stored form, so it is not offered.
module StoredValueCorpus
  FIXTURE_DIR = File.expand_path("../fixtures/rust_project", __dir__)
  RULE_AFTER = /invariant violated — (.*) \(given /
  ARGUMENT_GATE_KINDS = %w[AbsentArgument].freeze

  # One bluebook, the aggregate its `Write` steps store, and the corpus fixtures that write to it.
  SUBJECTS = [
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

  # @param name [String] a fixture's name under spec/corpus/rust_conformance
  # @return [Hash] the parsed fixture
  def fixture(name) = ConformanceCorpus.load(File.join(InMemoryDomain::ROOT, "spec/corpus/rust_conformance/#{name}.json"))

  # @param source [Hash] a parsed fixture
  # @return [Array<Hash>] its `Write` steps
  def write_steps(source) = source.fetch("steps").select { |step| step.fetch("verb").end_with?(".Write") }

  # The record's identity: the key, written as a value object or, where a bare scalar stands in
  # for one, as itself.
  #
  # @param args [Hash] a `Write` step's arguments
  # @return [String] the record's id
  def key_of(args) = (args["key"].is_a?(Hash) ? args["key"]["value"] : args["key"]).to_s

  # @param name [String] the fixture's name
  # @param args [Hash] a `Write` step's arguments
  # @return [String] the stored value's label in a disagreement
  def value_id(name, args) = "#{name}: #{key_of(args)}"

  # A step is accepted when its record exists in the frozen expect.
  #
  # @param source [Hash] a parsed fixture
  # @param step [Hash] one of its `Write` steps
  # @return [Boolean] whether dispatch accepted it
  def accepted?(source, step)
    record = "#{step.fetch("verb").delete_suffix(".Write")}##{key_of(step.fetch("args"))}"
    source.fetch("expect").fetch("instances").key?(record)
  end

  # @param source [Hash] a parsed fixture
  # @return [Array<Hash>] the frozen refusals of its `Write` steps, in step order
  def refused_writes(source)
    source.fetch("expect").fetch("refusals").select { |refusal| refusal.fetch("verb").end_with?(".Write") }
  end

  # Raises when two writes share a key, since a refusal could not then be told from an accept.
  #
  # @param name [String] the fixture's name
  # @param writes [Array<Hash>] its `Write` steps
  # @return [void]
  def refuse_shared_keys!(name, writes)
    keys = writes.map { |step| key_of(step.fetch("args")) }
    return if keys.uniq.size == keys.size

    raise "#{name}: two writes share a key, so a refusal cannot be told from an accept"
  end

  # @param name [String] the fixture's name
  # @return [Array<Array(Hash, Hash)>] each write's arguments and dispatch's refusal, or nil
  def dispatch_answers(name)
    source = fixture(name)
    writes = write_steps(source)
    refuse_shared_keys!(name, writes)
    refusals = refused_writes(source).each
    writes.map { |step| [step.fetch("args"), accepted?(source, step) ? nil : refusals.next] }
  end

  # @param refusal [Hash, nil] dispatch's refusal of a write
  # @return [Boolean] whether the argument gate refused it, so it has no stored form
  def argument_gate?(refusal) = refusal && ARGUMENT_GATE_KINDS.include?(refusal.fetch("kind"))

  # Every stored value a subject's fixtures write, with dispatch's refusal (nil when accepted).
  #
  # @param subject [Hash] one of `StoredValueCorpus::SUBJECTS`
  # @return [Array<Hash>] `:id`, `:fixture`, `:args`, `:refusal` and `:aggregate` per value
  def stored_values(subject)
    values = subject.fetch(:fixtures).flat_map do |name|
      dispatch_answers(name).map do |args, refusal|
        { id: value_id(name, args), fixture: name, args: args, refusal: refusal, aggregate: subject.fetch(:aggregate) }
      end
    end
    values.reject { |value| argument_gate?(value[:refusal]) }
  end

  # Boots a subject's bluebook in a registry of its own.
  #
  # @param subject [Hash] one of `StoredValueCorpus::SUBJECTS`
  # @return [Hecks::Runtime::Registry] the booted registry
  def subject_registry(subject)
    registry = Hecks::Runtime::Registry.new
    Hecks.with_registry(registry) do
      [InMemoryDomain::PERSISTENCE_PORT, InMemoryDomain::EXTRACTION_PORT, InMemoryDomain::MEMORY_ADAPTER,
       InMemoryDomain::PRISM_ADAPTER, File.join(FIXTURE_DIR, subject.fetch(:bluebook))].each { |file| Kernel.load(file) }
    end
    registry
  end

  # What an audit should say: the rule an invariant refusal names, or the refusal's own wording.
  # Dispatch names a command's own argument `Write.slugs`; a stored record has no command, so the
  # audit names the aggregate that holds it.
  #
  # @param value [Hash] one of {stored_values}
  # @return [Array(Symbol, String), nil] `[:rule, rule]`, `[:wording, words]`, or nil when accepted
  def expected_say(value)
    return nil unless value[:refusal]

    error = value[:refusal].fetch("error")
    rule = error[RULE_AFTER, 1]
    rule ? [:rule, rule] : [:wording, error.sub(/\AWrite\./, "#{value[:aggregate]}.")]
  end
end
