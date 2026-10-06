require "spec_helper"
require "hecks/fuzzing"
require "hecks/fuzzing/self_consistency"

# Each check kind must be able to fire: each `describe` breaks one production path, confirms
# the finding, then restores the original method in `ensure` and confirms a clean replay.
RSpec.describe "Hecks::Fuzzing::SelfConsistency" do
  SELF_CONSISTENCY_PIZZAS = File.join(InMemoryDomain::ROOT, "examples/pizzas")

  # One fixed sequence so every example, and its restore half, replays identical steps.
  STEPS = Hecks::Fuzzing::SequenceGenerator.generate(SELF_CONSISTENCY_PIZZAS, seed: 2, steps: 15).freeze

  def self_consistency_findings
    Hecks::Fuzzing::Replay.call(SELF_CONSISTENCY_PIZZAS, STEPS, self_consistency: true).fetch(:self_consistency)
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
        original.bind_call(self, entry)
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
