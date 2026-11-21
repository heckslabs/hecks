# frozen_string_literal: true

require "spec_helper"
require "json"
require "hecks/roundhouse/adapters/metering"

# Roundhouse's `Tokens` meter: a seeded usage record yields the used and saved figures by label.
RSpec.describe Hecks::Adapters::Metering do
  let(:coder) { { input: 2, output: 1_000, cache_creation: 0, cache_read: 1_000_000, model: "claude-opus-5-5" } }
  let(:helper) { { input: 0, output: 2_000_000, cache_creation: 0, cache_read: 0, model: "claude-sonnet-5-5" } }

  let(:rows) do
    [{ id: "m1", session: "s1", day: "2026-11-19", **coder },
     { id: "m2", session: "s1", day: "2026-11-20", **coder },
     { id: "m3", session: "s2", day: "2026-11-20", **helper }]
  end

  let(:runs) { { "s1" => { run: "r1", agent: "coder", work: "tiles" }, "s2" => { run: "r2", agent: "reviewer", work: "tiles" } } }

  let(:facts) do
    text = described_class.new(settings: { usage: -> { rows }, runs: -> { runs } }).tokens[:text]
    JSON.parse(text, symbolize_names: true)
  end

  def line(group, key, name = group.to_s.delete_prefix("by_"))
    facts[group].find { |entry| entry[name.to_sym] == key }
  end

  it "totals the split of tokens used", :aggregate_failures do
    expect(facts[:total]).to include(input: 4, output: 2_002_000, cache_read: 2_000_000, tokens: 4_002_004)
    expect(line(:by_day, "2026-11-20")).to include(output: 2_001_000, cache_read: 1_000_000)
  end

  it "sums the sessions behind a Work item and a role", :aggregate_failures do
    expect(line(:by_item, "tiles")[:tokens]).to eq(4_002_004)
    expect(line(:by_role, "coder")[:cache_read]).to eq(2_000_000)
    expect(line(:by_session, "s2")[:output]).to eq(2_000_000)
  end

  it "prices the tokens in dollars from the declared table" do
    expect(line(:by_session, "s2")[:dollars]).to eq(30.0)
  end

  it "counts the prompt cache saving as cache reads at nine tenths of fresh input", :aggregate_failures do
    cache = facts[:saved].find { |entry| entry[:label].start_with?("prompt cache") }
    expect(cache[:tokens]).to eq(1_800_000)
    expect(cache[:dollars]).to eq(27.0)
  end

  it "counts the model routing saving as the same tokens at Opus price, less their cost", :aggregate_failures do
    routing = facts[:saved].find { |entry| entry[:label].start_with?("model routing") }
    expect(routing[:tokens]).to eq(2_000_000)
    expect(routing[:dollars]).to eq(120.0)
  end

  it "names what it cannot measure rather than guessing it" do
    expect(facts[:not_measured].map { |text| text.split(":").first }).to eq(["Hecks door", "work not redone"])
  end
end
