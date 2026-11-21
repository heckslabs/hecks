# frozen_string_literal: true

require "spec_helper"
require "hecks/roundhouse/adapters/metering"

# Roundhouse's price table: each model family is priced at its current published rates.
RSpec.describe Hecks::Adapters::Metering::PriceTable do
  def usage(**counts) = { input: 0, output: 0, cache_creation: 0, cache_read: 0, **counts }

  it "prices one claude-opus-5-5 row at $4 in, $20 out, $5 cache write and $0.20 cache read" do
    row = usage(input: 1_000_000, output: 1_000_000, cache_creation: 1_000_000, cache_read: 1_000_000)
    expect(described_class.dollars("claude-opus-5-5", row)).to eq(29.2)
  end

  it "prices a claude-sonnet-5-5 row at $2 in, $10 out, $2.50 cache write and $0.10 cache read" do
    row = usage(input: 1_000_000, output: 1_000_000, cache_creation: 1_000_000, cache_read: 1_000_000)
    expect(described_class.dollars("claude-sonnet-5-5", row)).to eq(14.6)
  end

  it "prices a claude-haiku-5-5 row at $0.10 in, $0.50 out, $0.125 cache write and $0.01 cache read" do
    row = usage(input: 10_000, output: 10_000, cache_creation: 10_000, cache_read: 10_000)
    expect(described_class.dollars("claude-haiku-5-5", row)).to be_within(1e-12).of(0.00735)
  end

  it "prices a Haiku request whose prompt is over 100,000 tokens at the long-prompt rates" do
    row = usage(input: 50_000, output: 1_000_000, cache_read: 50_001)
    expect(described_class.dollars("claude-haiku-5-5", row)).to eq(2.5 + (50_000 * 0.5 / 1e6) + (50_001 * 0.05 / 1e6))
  end

  it "prices an unknown model as Opus" do
    expect(described_class.dollars("claude-mystery-9", usage(output: 1_000_000))).to eq(20.0)
  end

  it "saves each row's cache reads at its own model's rate", :aggregate_failures do
    expect(described_class.read_saving("claude-opus-5-5", usage(cache_read: 1_000_000))).to eq(3.8)
    expect(described_class.read_saving("claude-haiku-5-5", usage(cache_read: 50_000))).to be_within(1e-12).of(0.0045)
  end

  it "counts the tokens a cache read saves as one less its read rate over its input rate", :aggregate_failures do
    expect(described_class.read_saving_tokens("claude-sonnet-5-5", usage(cache_read: 1_000_000))).to eq(950_000.0)
    expect(described_class.read_saving_tokens("claude-haiku-5-5", usage(cache_read: 1_000_000))).to eq(900_000.0)
  end
end
