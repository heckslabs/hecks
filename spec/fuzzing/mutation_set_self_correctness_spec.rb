require "spec_helper"
require "hecks/fuzzing"
require "hecks/fuzzing/self_consistency"

# Shows `SelfConsistency.check` cannot see a defect in the `:set` branch of
# `EntityElement#apply_to_element`, while `mutations_match_recompute` (docs/decisions/0056) can.
# Both sides of a persistence round trip derive from the same corrupted value.
#
# The defect is installed as a singleton override (`apply_to_element` is a module_function)
# and restored in an `ensure`, as in spec/fuzzing/self_consistency_spec.rb.
RSpec.describe "Ruby self-correctness — a defect only mutations_match_recompute can see" do
  MUTATION_SET_NESTED_PIECES = File.join(InMemoryDomain::ROOT, "qa/stress_domains/nested_pieces")

  # Seed 2 is the smallest fixed seed whose sequence dispatches `Board.Label` (a plain
  # entity-owned `:set`) at least once; every example replays the same steps.
  MUTATION_SET_STEPS = Hecks::Fuzzing::SequenceGenerator.generate(MUTATION_SET_NESTED_PIECES, seed: 2, steps: 25).freeze

  # Plants a defect in the `:set` branch only: unwraps the resolved Value, mangles the raw
  # scalar, and re-coerces it via `Value.for_attribute`, so other ops stay real.
  def with_broken_set_mutation
    original = Hecks::Runtime::EntityElement.method(:apply_to_element)
    Hecks::Runtime::EntityElement.define_singleton_method(:apply_to_element) do |rules, aggregate, entity, element,
                                                                                  mutation, args, pre = element|
      if mutation.op == :set
        value     = rules.resolve_source(mutation.source, args)
        raw       = value.is_a?(Hecks::Runtime::Value) ? value.to_h[:value] : value
        corrupted = raw.is_a?(String) ? "#{raw}_CORRUPTED" : raw
        attribute = entity.attribute(mutation.target)
        element[mutation.target] = attribute ? Hecks::Runtime::Value.for_attribute(aggregate, attribute, corrupted) : corrupted
      else
        original.call(rules, aggregate, entity, element, mutation, args, pre)
      end
    end

    yield
  ensure
    Hecks::Runtime::EntityElement.define_singleton_method(:apply_to_element, original)
  end

  it "is clean against a real domain with nothing broken (both checks agree there is nothing to find)" do
    history = Hecks::Fuzzing::Replay.call(MUTATION_SET_NESTED_PIECES, MUTATION_SET_STEPS, self_consistency: true)

    findings = history[:self_consistency]
    expect(findings[:rehydration]).to be_empty
    expect(findings[:idempotency]).to be_empty
    expect(findings[:value_object_round_trip]).to be_empty
    expect(Hecks::Fuzzing::Properties.mutations_match_recompute(history)).to be(true)
  end

  it "leaves SelfConsistency.check completely clean even though a real :set defect is live" do
    with_broken_set_mutation do
      history  = Hecks::Fuzzing::Replay.call(MUTATION_SET_NESTED_PIECES, MUTATION_SET_STEPS, self_consistency: true)
      findings = history[:self_consistency]

      # Both the live and rehydrated states trace back to the same corrupted
      # `apply_to_element` call, and the wrong value round-trips through JSON intact.
      expect(findings[:rehydration]).to be_empty
      expect(findings[:idempotency]).to be_empty
      expect(findings[:value_object_round_trip]).to be_empty
    end
  end

  it "names the SAME defect via mutations_match_recompute — the genuinely third, independent computation" do
    with_broken_set_mutation do
      history = Hecks::Fuzzing::Replay.call(MUTATION_SET_NESTED_PIECES, MUTATION_SET_STEPS)
      result  = Hecks::Fuzzing::Properties.mutations_match_recompute(history)

      expect(result).to be_a(String)
      expect(result).to include("Board.Label").and include("set on label").and include("_CORRUPTED")
    end
  end

  it "is clean again once the mutation-application path is restored" do
    history = Hecks::Fuzzing::Replay.call(MUTATION_SET_NESTED_PIECES, MUTATION_SET_STEPS, self_consistency: true)

    expect(history[:self_consistency][:rehydration]).to be_empty
    expect(Hecks::Fuzzing::Properties.mutations_match_recompute(history)).to be(true)
  end
end
