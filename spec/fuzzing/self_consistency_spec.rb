require "spec_helper"
require "hecks/fuzzing"
require "hecks/fuzzing/self_consistency"

# Each check kind must be able to fire: each `describe` breaks one production path, confirms
# the finding, then restores the original method after the example and confirms a clean replay.
RSpec.describe "Hecks::Fuzzing::SelfConsistency", :aggregate_failures do
  SELF_CONSISTENCY_PIZZAS = File.join(InMemoryDomain::ROOT, "examples/pizzas")

  # One fixed sequence so every example, and its restore half, replays identical steps.
  STEPS = Hecks::Fuzzing::SequenceGenerator.generate(SELF_CONSISTENCY_PIZZAS, seed: 2, steps: 15).freeze

  SELF_CONSISTENCY_LEAK_KEY = "__self_consistency_spec_leak__".freeze

  def self_consistency_findings
    Hecks::Fuzzing::Replay.call(SELF_CONSISTENCY_PIZZAS, STEPS, self_consistency: true).fetch(:self_consistency)
  end

  # Swaps an instance method for the lambda the block returns (given the original), and puts
  # the original back after the example.
  def replace_method(klass, name)
    original = klass.instance_method(name)
    (@replaced ||= []) << [klass, name, original]
    replacement = yield(original)
    klass.send(:define_method, name, &replacement)
  end

  after do
    (@replaced || []).each { |klass, name, original| klass.send(:define_method, name, original) }
  end

  # The entry with a counter written into its saved state, so repeated writes differ.
  def leak_into(entry, counter)
    entry.dup.tap { |copy| copy.state = copy.state.merge(SELF_CONSISTENCY_LEAK_KEY => counter) }
  end

  # An `append` whose saved state carries a hidden counter that grows with every call.
  def leaking_append(original)
    counter = 0
    spec = self
    lambda do |entry|
      counter += 1
      entry = spec.leak_into(entry, counter) if entry.save?
      original.bind(self).call(entry)
    end
  end

  def corrupt_value(value)
    case value
    when String then "#{value}_CORRUPTED"
    when Hash   then value.transform_values { |v| corrupt_value(v) }
    when Array  then value.map { |v| corrupt_value(v) }
    else value
    end
  end

  it "is clean against a real domain with nothing broken" do
    findings = self_consistency_findings

    expect(findings.values_at(:rehydration, :idempotency, :value_object_round_trip)).to all(be_empty)
  end

  describe "check 1 — rehydration" do
    it "fires when cold-reading a durable store silently loses every write" do
      replace_method(Hecks::Adapters::Heki, :all) { ->(**_kwargs) { [] } }

      findings = self_consistency_findings
      expect(findings[:rehydration]).not_to be_empty
      expect(findings[:rehydration].first).to include(field: "rehydration", rehydrated: {})
    end

    it "is clean again once the read path is restored" do
      expect(self_consistency_findings[:rehydration]).to be_empty
    end
  end

  describe "check 2 — replay idempotency" do
    context "with a hidden counter leaking into what is written" do
      before do
        replace_method(Hecks::Adapters::Heki, :append) { |original| leaking_append(original) }
        @findings = self_consistency_findings[:idempotency]
      end

      it "fires when a hidden counter leaks into what a repeated replay durably writes" do
        expect(@findings).not_to be_empty
        expect(@findings.first[:field]).to eq("idempotency")
      end

      it "shows the leaked counter differing between the two runs" do
        once, twice = [:once, :twice].map { |run| @findings.first[run].values.first[:__self_consistency_spec_leak__] }

        expect(once).not_to eq(twice)
      end
    end

    it "is clean again once the write path is restored" do
      expect(self_consistency_findings[:idempotency]).to be_empty
    end
  end

  describe "check 3 — value object JSON round trip" do
    it "fires when the serialize side silently corrupts a field" do
      spec = self
      replace_method(Hecks::Runtime::Value, :to_json) { ->(*_args) { JSON.generate(spec.corrupt_value(to_h)) } }

      findings = self_consistency_findings
      expect(findings[:value_object_round_trip]).not_to be_empty
      expect(findings[:value_object_round_trip].first[:field]).to eq("value_object_round_trip")
    end

    it "is clean again once the serialize path is restored" do
      expect(self_consistency_findings[:value_object_round_trip]).to be_empty
    end
  end
end
