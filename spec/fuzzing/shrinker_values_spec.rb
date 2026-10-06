require "spec_helper"
require "hecks/fuzzing/shrinker"

# The value-simplification pass of `Hecks::Fuzzing::Shrinker`: after steps and argument keys are
# gone, each surviving argument value is offered a simpler stand-in. The block stands in for
# "does this candidate still reproduce", as in shrinker_spec.rb.
RSpec.describe Hecks::Fuzzing::Shrinker, :aggregate_failures do
  def step(verb, **args) = { "verb" => verb, "args" => args.transform_keys(&:to_s) }

  def args_of_first(result) = result.steps.first["args"]

  it "replaces a value the finding does not depend on with the simplest one" do
    steps = [step("Open", name: "a long unneeded name", count: 42, tags: %w[x y z])]

    present = ->(candidate) { %w[name count tags].all? { |key| candidate.first["args"].key?(key) } }
    result = described_class.call(steps) { |candidate| present.call(candidate) }

    expect(args_of_first(result)).to eq("name" => "", "count" => 0, "tags" => [])
  end

  it "keeps a value the finding needs" do
    steps = [step("Open", name: "boom", count: 42)]

    result = described_class.call(steps) { |candidate| candidate.first["args"]["name"] == "boom" }

    expect(args_of_first(result)).to eq("name" => "boom")
  end

  it "falls back to the shorter stand-in when the simplest does not reproduce" do
    steps = [step("Open", count: 42)]

    result = described_class.call(steps) { |candidate| candidate.first["args"]["count"].to_i.positive? }

    expect(args_of_first(result)).to eq("count" => 1)
  end

  it "simplifies inside a nested hash, key by key" do
    steps = [{ "verb" => "Open", "args" => { "address" => { "city" => "Paris", "zip" => 75_001 } } }]

    result = described_class.call(steps) do |candidate|
      candidate.first["args"].dig("address", "city") == "Paris"
    end

    expect(result.steps.first["args"]["address"]).to eq("city" => "Paris", "zip" => 0)
  end

  it "does not mutate the steps it was given" do
    steps = [step("Open", name: "keep me")]

    described_class.call(steps) { |candidate| candidate.first["verb"] == "Open" }

    expect(steps.first["args"]).to eq("name" => "keep me")
  end

  it "stops spending once the budget is gone" do
    steps = [step("Open", a: "x" * 5, b: "y" * 5, c: "z" * 5)]
    calls = 0

    result = described_class.call(steps, budget: 3) { calls += 1 }

    expect(calls).to be <= 3
    expect(result.exhausted).to be(true)
  end
end
