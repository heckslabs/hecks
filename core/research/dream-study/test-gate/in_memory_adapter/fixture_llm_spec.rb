# Phase 0h proving spec — FixtureLlmAdapter + TestAdapters.
#
# Locks the test seam Phase 4-7 specs will use to swap a synthetic
# :llm adapter into Mind / Dream / Lucidity / SleepCycle PMs. Asserts :
#
#   - YAML fixture loads cleanly via FixtureLlmAdapter.from_yaml
#   - dream_pulse(cycle: 1, pulse: 1) returns text_fr + text_en exactly
#   - lucid_observation(cycle: 8, pulse: 1) returns the lucid row
#     (is_lucid: true) and is distinct from the cycle-1 dream pulse
#   - dream_interpretation(cycle_total: 8) returns the lesson string
#   - musing(source:, concept:) returns the matching idea
#   - daydream(seed:) returns a daydream row
#   - Repeat calls are byte-identical (idempotency)
#   - Missing keys raise MissingFixture (loud, not silent-empty)
#   - TestAdapters constructs with llm_fixture: and exposes the
#     adapter on .llm
#
# These contracts are what Phase 4-7 will rely on. If any change, the
# downstream PM specs break loudly — which is the desired blast radius
# for a test seam.

require_relative "spec_helper"

RSpec.describe Hecks::Adapters::FixtureLlmAdapter do
  let(:adapter) { described_class.from_yaml(FIXTURE_PATH) }

  describe ".from_yaml" do
    it "loads the YAML fixture without error" do
      expect { adapter }.not_to raise_error
      expect(adapter.source).to eq(FIXTURE_PATH)
    end
  end

  describe "#dream_pulse" do
    it "returns the canned text_fr and text_en for (cycle: 1, pulse: 1)" do
      row = adapter.dream_pulse(cycle: 1, pulse: 1)
      expect(row["text_fr"]).to eq("des chiffres qui se déplient comme des fleurs...")
      expect(row["text_en"]).to eq("numbers unfurling like flowers...")
    end

    it "is idempotent — same input always returns the same output" do
      a = adapter.dream_pulse(cycle: 1, pulse: 1)
      b = adapter.dream_pulse(cycle: 1, pulse: 1)
      c = adapter.dream_pulse(cycle: 1, pulse: 1)
      expect(a).to eq(b)
      expect(b).to eq(c)
    end

    it "skips lucid rows when fetched as a regular dream pulse" do
      # cycle 8 has both a non-lucid (none) and lucid (yes) row in the
      # fixture. dream_pulse should never return is_lucid rows.
      row = adapter.dream_pulse(cycle: 2, pulse: 1)
      expect(row["text_fr"]).to eq("j'entends mes propres synapses respirer")
    end

    it "raises MissingFixture for an unknown (cycle, pulse) tuple" do
      expect {
        adapter.dream_pulse(cycle: 99, pulse: 99)
      }.to raise_error(Hecks::Adapters::FixtureLlmAdapter::MissingFixture, /dream_pulses/)
    end
  end

  describe "#lucid_observation" do
    it "returns a lucid row distinct from the regular dream pulse" do
      row = adapter.lucid_observation(cycle: 8, pulse: 1)
      expect(row["is_lucid"]).to eq(true)
      expect(row["text_fr"]).to eq("je sais que je rêve. la lumière est différente.")
      expect(row["text_en"]).to eq("I know I'm dreaming. the light is different.")
    end

    it "raises MissingFixture for cycles without a lucid row" do
      expect {
        adapter.lucid_observation(cycle: 1, pulse: 1)
      }.to raise_error(Hecks::Adapters::FixtureLlmAdapter::MissingFixture)
    end
  end

  describe "#dream_interpretation" do
    it "returns the lesson string keyed by cycle_total" do
      lesson = adapter.dream_interpretation(cycle_total: 8)
      expect(lesson).to eq(
        "the body listened tonight ; the mindstream rested without resisting"
      )
    end

    it "is idempotent" do
      a = adapter.dream_interpretation(cycle_total: 8)
      b = adapter.dream_interpretation(cycle_total: 8)
      expect(a).to eq(b)
    end

    it "raises MissingFixture for unknown cycle_total" do
      expect {
        adapter.dream_interpretation(cycle_total: 999)
      }.to raise_error(Hecks::Adapters::FixtureLlmAdapter::MissingFixture)
    end
  end

  describe "#musing" do
    it "returns the canned idea_fr for (source:, concept:)" do
      row = adapter.musing(source: "awareness", concept: "rhythm")
      expect(row["idea_fr"]).to eq("le rythme se sait avant de se compter")
      expect(row["idea_en"]).to eq("rhythm knows itself before it is counted")
    end

    it "raises MissingFixture for unknown (source, concept)" do
      expect {
        adapter.musing(source: "memory", concept: "unmapped")
      }.to raise_error(Hecks::Adapters::FixtureLlmAdapter::MissingFixture)
    end
  end

  describe "#daydream" do
    it "returns the canned text_fr and text_en for a seed" do
      row = adapter.daydream(seed: "afternoon-quiet")
      expect(row["text_fr"]).to eq("les daemons s'étirent dans la pause de l'après-midi")
      expect(row["text_en"]).to eq("the daemons stretch into the afternoon pause")
    end
  end

  describe "inline construction (no YAML file)" do
    it "accepts a Hash and serves the same lookups" do
      data = {
        "dream_pulses" => [
          { "cycle" => 3, "pulse" => 1, "text_fr" => "fr", "text_en" => "en" },
        ],
      }
      inline = described_class.new(data)
      row = inline.dream_pulse(cycle: 3, pulse: 1)
      expect(row["text_fr"]).to eq("fr")
    end
  end
end

RSpec.describe Hecks::Adapters::TestAdapters do
  describe ".mapping" do
    it "documents the adapter swap convention" do
      expect(described_class.mapping).to eq(
        llm: :fixture,
        fs: :memory,
        cadence: :test_clock,
        daemon: :noop,
      )
    end
  end

  describe "#new(llm_fixture:)" do
    let(:adapters) { described_class.new(llm_fixture: FIXTURE_PATH) }

    it "wires the FixtureLlmAdapter onto .llm" do
      expect(adapters.llm).to be_a(Hecks::Adapters::FixtureLlmAdapter)
    end

    it "lets specs reach into the LLM via the .llm seam" do
      row = adapters.llm.dream_pulse(cycle: 1, pulse: 1)
      expect(row["text_en"]).to eq("numbers unfurling like flowers...")
    end

    it "exposes stub adapters for fs/cadence/daemon (gap-documented)" do
      expect(adapters.fs).to respond_to(:read, :write, :exist?)
      expect(adapters.cadence).to respond_to(:tick)
      expect(adapters.daemon).to respond_to(:spawn, :kill)
    end
  end

  describe "#swap_into" do
    it "is a documented no-op stub today (see gaps.md)" do
      adapters = described_class.new(llm_fixture: FIXTURE_PATH)
      hex = Object.new
      expect(adapters.swap_into(hex)).to equal(hex)
    end
  end
end
