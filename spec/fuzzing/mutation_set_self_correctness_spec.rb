require "spec_helper"
require "hecks/fuzzing"
require "hecks/fuzzing/self_consistency"

# Shows `SelfConsistency.check` cannot see a defect in the `:set` branch of
# `EntityElement#apply_to_element`, while `mutations_match_recompute` (docs/decisions/0056) can.
# Both sides of a persistence round trip derive from the same corrupted value.
#
# The defect is installed as a singleton override (`apply_to_element` is a module_function)
# and restored in an `ensure`, as in spec/fuzzing/self_consistency_spec.rb.
RSpec.describe "Ruby self-correctness — a defect only mutations_match_recompute can see", :aggregate_failures do
  MUTATION_SET_NESTED_PIECES = File.join(InMemoryDomain::ROOT, "qa/stress_domains/nested_pieces")

  # Seed 4 is the smallest fixed seed whose sequence dispatches `Board.Label` (a plain
  # entity-owned `:set`) with arguments that apply; every example replays the same steps.
  MUTATION_SET_STEPS = Hecks::Fuzzing::SequenceGenerator.generate(MUTATION_SET_NESTED_PIECES, seed: 4, steps: 25).freeze

  def replay_set_steps(**options)
    Hecks::Fuzzing::Replay.call(MUTATION_SET_NESTED_PIECES, MUTATION_SET_STEPS, **options)
  end

  # The resolved source, unwrapped from its Value and mangled when it is a string.
  def corrupted_scalar(rules, mutation, args)
    value = rules.resolve_source(mutation.source, args)
    raw   = value.is_a?(Hecks::Runtime::Value) ? value.to_h[:value] : value
    raw.is_a?(String) ? "#{raw}_CORRUPTED" : raw
  end

  # The `:set` branch of `apply_to_element`, given its positional arguments as one list
  # (rules, aggregate, entity, element, mutation, args), with the corrupted value re-coerced.
  def corrupt_set(call)
    rules, aggregate, entity, element, mutation, args = call
    corrupted = corrupted_scalar(rules, mutation, args)
    attribute = entity.attribute(mutation.target)
    coerced = attribute ? Hecks::Runtime::Value.for_attribute(aggregate, attribute, corrupted) : corrupted
    element[mutation.target] = coerced
    coerced
  end

  # Plants a defect in the `:set` branch only, so other ops stay real.
  def with_broken_set_mutation
    original = Hecks::Runtime::EntityElement.method(:apply_to_element)
    spec = self
    Hecks::Runtime::EntityElement.define_singleton_method(:apply_to_element) do |*call|
      call[4].op == :set ? spec.corrupt_set(call) : original.call(*call)
    end

    yield
  ensure
    Hecks::Runtime::EntityElement.define_singleton_method(:apply_to_element, original)
  end

  it "is clean against a real domain with nothing broken (both checks agree there is nothing to find)" do
    history = replay_set_steps(self_consistency: true)

    expect(history[:self_consistency].values_at(:rehydration, :idempotency, :value_object_round_trip)).to all(be_empty)
    expect(Hecks::Fuzzing::Properties.mutations_match_recompute(history)).to be(true)
  end

  it "leaves SelfConsistency.check completely clean even though a real :set defect is live" do
    with_broken_set_mutation do
      findings = replay_set_steps(self_consistency: true)[:self_consistency]

      # Both the live and rehydrated states trace back to the same corrupted
      # `apply_to_element` call, and the wrong value round-trips through JSON intact.
      expect(findings.values_at(:rehydration, :idempotency, :value_object_round_trip)).to all(be_empty)
    end
  end

  it "names the SAME defect via mutations_match_recompute — the genuinely third, independent computation" do
    with_broken_set_mutation do
      result = Hecks::Fuzzing::Properties.mutations_match_recompute(replay_set_steps)

      expect(result).to be_a(String).and include("Board.Label", "set on label", "_CORRUPTED")
    end
  end

  it "is clean again once the mutation-application path is restored" do
    history = replay_set_steps(self_consistency: true)

    expect(history[:self_consistency][:rehydration]).to be_empty
    expect(Hecks::Fuzzing::Properties.mutations_match_recompute(history)).to be(true)
  end
end
