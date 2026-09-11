require "spec_helper"
require "hecks/fuzzing"
require "hecks/fuzzing/self_consistency"

# PROVING EACH CHECK KIND CAN ACTUALLY FIRE — not just that it stays
# quiet against a well-behaved domain (the "clean" example below already
# covers that; on its own it would prove nothing about whether a real
# regression could ever be caught). Each `describe` block below
# temporarily breaks ONE real, production code path the corresponding
# check depends on — `Adapters::Heki#all` (the cold-read side of
# rehydration), `Adapters::Heki#append` (the durable-write side, made to
# leak a hidden counter into what gets persisted), `Runtime::Value#to_json`
# (the serialize half of check 3's own round trip) — confirms the check
# fires, then restores the original method and confirms a follow-up
# replay is clean again. `instance_method`/`define_method(name, method)`
# is what makes the restore exact: the ORIGINAL `UnboundMethod` is
# captured before the break and reinstalled afterward, in an `ensure`, so
# a failing expectation never leaves a later example running against a
# broken runtime.
#
# THE OVERLAP IS REAL, NOT A TEST BUG. `check_rehydration`/
# `check_idempotency`/`check_value_object_round_trip` all ultimately rest
# on the SAME JSON serialize/deserialize boundary (`Adapters::Heki`'s own
# journal write calls `Value#to_json` on every nested value object;
# `Value.build` is the one door every one of them reconstructs through) —
# see `lib/hecks/fuzzing/self_consistency.rb`'s own header. So the
# `Heki#all` break below fires ONLY `check_rehydration` (the read side,
# in isolation), but the `Value#to_json` break fires BOTH `check_
# rehydration` (Heki's own journal write is corrupted too) and `check_
# value_object_round_trip` — that is a true fact about how deeply these
# three checks share one mechanism, not an artifact of a sloppy break.
RSpec.describe "Hecks::Fuzzing::SelfConsistency" do
  PIZZAS = File.join(InMemoryDomain::ROOT, "examples/pizzas")

  # ONE FIXED, DETERMINISTIC SEQUENCE — seed 2 is not special, just
  # pinned so every example (and the "restore" half of each) replays the
  # identical steps and gets the identical, reproducible baseline.
  STEPS = Hecks::Fuzzing::SequenceGenerator.generate(PIZZAS, seed: 2, steps: 15).freeze

  def self_consistency_findings
    Hecks::Fuzzing::Replay.call(PIZZAS, STEPS, self_consistency: true).fetch(:self_consistency)
  end

  it "is clean against a real domain with nothing broken" do
    findings = self_consistency_findings

    expect(findings[:rehydration]).to be_empty
    expect(findings[:idempotency]).to be_empty
    expect(findings[:value_object_round_trip]).to be_empty
  end

  describe "check 1 — rehydration" do
    it "fires when cold-reading a durable store silently loses every write" do
      original = Hecks::Adapters::Heki.instance_method(:all)
      Hecks::Adapters::Heki.send(:define_method, :all) { |**_kwargs| [] }

      findings = self_consistency_findings
      expect(findings[:rehydration]).not_to be_empty
      expect(findings[:rehydration].first[:field]).to eq("rehydration")
      expect(findings[:rehydration].first[:rehydrated]).to eq({})
    ensure
      Hecks::Adapters::Heki.send(:define_method, :all, original)
    end

    it "is clean again once the read path is restored" do
      expect(self_consistency_findings[:rehydration]).to be_empty
    end
  end

  describe "check 2 — replay idempotency" do
    it "fires when a hidden counter leaks into what a repeated replay durably writes" do
      counter  = 0
      original = Hecks::Adapters::Heki.instance_method(:append)
      Hecks::Adapters::Heki.send(:define_method, :append) do |entry|
        counter += 1
        if entry.save?
          entry = entry.dup
          entry.state = entry.state.merge("__self_consistency_spec_leak__" => counter)
        end
        original.bind(self).call(entry)
      end

      findings = self_consistency_findings
      expect(findings[:idempotency]).not_to be_empty
      idempotency = findings[:idempotency].first
      expect(idempotency[:field]).to eq("idempotency")
      once_leak  = idempotency[:once].values.first[:__self_consistency_spec_leak__]
      twice_leak = idempotency[:twice].values.first[:__self_consistency_spec_leak__]
      expect(once_leak).not_to eq(twice_leak)
    ensure
      Hecks::Adapters::Heki.send(:define_method, :append, original)
    end

    it "is clean again once the write path is restored" do
      expect(self_consistency_findings[:idempotency]).to be_empty
    end
  end

  describe "check 3 — value object JSON round trip" do
    it "fires when the serialize side silently corrupts a field" do
      original = Hecks::Runtime::Value.instance_method(:to_json)
      corrupt = lambda do |value|
        case value
        when String then "#{value}_CORRUPTED"
        when Hash    then value.transform_values { |v| corrupt.call(v) }
        when Array   then value.map { |v| corrupt.call(v) }
        else value
        end
      end
      Hecks::Runtime::Value.send(:define_method, :to_json) { |*_args| JSON.generate(corrupt.call(to_h)) }

      findings = self_consistency_findings
      expect(findings[:value_object_round_trip]).not_to be_empty
      expect(findings[:value_object_round_trip].first[:field]).to eq("value_object_round_trip")
    ensure
      Hecks::Runtime::Value.send(:define_method, :to_json, original)
    end

    it "is clean again once the serialize path is restored" do
      expect(self_consistency_findings[:value_object_round_trip]).to be_empty
    end
  end
end
