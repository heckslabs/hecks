require "spec_helper"
require "hecks/cli/stores"

# `flat` unwraps the value objects a record serializes as, so it reads as plain fields.
RSpec.describe Hecks::CLI::Stores, ".flatten" do
  it "unwraps a value object to its value" do
    expect(described_class.flatten("status" => { "value" => "concluded" })).to eq("status" => "concluded")
  end

  it "unwraps at any depth, through arrays" do
    wrapped = { "rows" => [{ "turns" => { "value" => 2 } }] }

    expect(described_class.flatten(wrapped)).to eq("rows" => [{ "turns" => 2 }])
  end

  it "keeps a hash that has more than a value" do
    kept = { "value" => 1, "unit" => "kg" }

    expect(described_class.flatten("weight" => kept)).to eq("weight" => kept)
  end

  it "leaves a plain scalar as it is" do
    expect(described_class.flatten("id" => "b-1")).to eq("id" => "b-1")
  end
end
