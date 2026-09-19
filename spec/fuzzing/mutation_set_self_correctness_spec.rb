require "spec_helper"
require "hecks/fuzzing"
require "hecks/fuzzing/self_consistency"

# The Ruby self-correctness track's own first piece of evidence (docs/
# decisions/0056). Every other check this practice runs before this file
# existed was either differential (Ruby vs the compiled Rust conformance
# binary — `bin/qa_sweep`'s own `diff_ruby_vs_rust`, `Properties.check`'s
# own dispatch/query/guard properties, all ultimately comparing two
# engines) or a same-process persistence round trip (`SelfConsistency`'s
# own `check_rehydration`/`check_idempotency` — see that file's own
# header: hecks is not event-sourced, `Ports::Persistence::AppendOnly`
# stores the full post-mutation state, so both the "live" and
# "rehydrated" sides of that comparison trace back to the exact same
# single `step_apply_mutations`/`EntityElement#apply_to_element` call).
# Neither of those can ever catch a bug in the mutation-application logic
# itself — a wrong value silently computed once is silently baked into
# every side of every comparison either check can make.
#
# This proves the gap is real, not merely argued: a defect planted
# directly in `EntityElement#apply_to_element`'s own `:set` branch (the
# real production code path `mutations_match_recompute`'s new `:set`
# coverage — `lib/hecks/fuzzing/properties/dispatch_and_mutations.rb`'s
# own `#recompute_set` — exists to check) leaves `SelfConsistency.check`
# completely clean (rehydration, idempotency, and the value-object round
# trip all report zero findings, because the corrupted value round-trips
# through Heki's own JSON boundary perfectly faithfully — corruption
# survives serialization just fine, it just isn't the value a correct
# dispatch should have produced in the first place) while `Properties.
# mutations_match_recompute` — a genuinely third, independently-written
# computation, re-deriving the expected value from the mutation's own
# declared source rather than reading back whatever the real dispatch
# already computed — names it immediately.
#
# Same monkeypatch idiom `spec/fuzzing/self_consistency_spec.rb` already
# uses (that file's own header explains why: `instance_method`/
# `define_method(name, method)` captures the original `UnboundMethod`
# before the break and reinstalls it afterward, in an `ensure`, so a
# failing expectation never leaves a later example running against a
# broken runtime) — `EntityElement.apply_to_element` is a `module_
# function` (that file's own `module_function` line), so the override is
# installed as a singleton method via `define_singleton_method` and
# restored the same way, rather than `instance_method`/`define_method`
# (which target a class's own instance methods, not a module's own
# module-function).
RSpec.describe "Ruby self-correctness — a defect only mutations_match_recompute can see" do
  MUTATION_SET_NESTED_PIECES = File.join(InMemoryDomain::ROOT, "qa/stress_domains/nested_pieces")

  # Seed 2 — pinned, not special: the smallest fixed seed against this
  # domain whose own generated sequence happens to dispatch `Board.Label`
  # (an entity-owned, plain `:set` — no `append:`/`remove:`/`multiply:`/
  # `clamp:`) at least once, confirmed live before this file existed
  # (`qa/stress_domains/nested_pieces`'s own bluebook: `sets :label`,
  # `entity "Board"`). Every example below replays the same steps, so a
  # "fires" example and its own "clean again" twin are directly
  # comparable.
  MUTATION_SET_STEPS = Hecks::Fuzzing::SequenceGenerator.generate(MUTATION_SET_NESTED_PIECES, seed: 2, steps: 25).freeze

  # Plants the defect: `EntityElement#apply_to_element`'s own `:set`
  # branch (entity_element.rb) resolves a source via `rules.resolve_
  # source`, which — for a command's own declared attribute — already
  # arrives as an already-coerced `Runtime::Value` (`normalize_args` ran
  # before dispatch ever reaches mutation application), not a bare
  # scalar; this override unwraps to the raw scalar the same way, mangles
  # it, and re-coerces through the same `Value.for_attribute` call
  # production uses — a realistic shape for "the wrong raw value reached
  # the coercion door," not a contrived one only a test double could
  # produce. Every other mutation op (`:append`/`:remove`/`:multiply`/
  # `:clamp`/`:corrects`) is left completely alone, delegated straight to
  # the real, unbroken implementation — this defect is scoped to `:set`
  # alone, on purpose, so a finding it produces can only ever be about
  # `:set`.
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

      # The structural blind spot, demonstrated, not asserted from
      # reading code alone — both the "live" state SelfConsistency
      # snapshots and the "rehydrated" state it folds back from Heki's
      # own journal trace back to the same already-corrupted
      # `apply_to_element` call; the corrupted value round-trips through
      # JSON serialize/deserialize perfectly faithfully (it is a
      # perfectly well-formed `BoardLabel`, just the wrong one), so there
      # is nothing for a same-process persistence check to disagree with
      # here, ever, no matter how many seeds this ran against.
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
