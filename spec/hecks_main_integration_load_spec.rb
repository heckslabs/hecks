# frozen_string_literal: true

require "spec_helper"
require "hecks/hecks/adapters/main_verification"

# How hard a verification of a landed commit may work in its clean copy: the Tickets world's
# `main_verification` line holds the workers and sets the niceness of every command it runs,
# and a checkout without the line is left as it was.
RSpec.describe Hecks::Adapters::MainIntegration::Load do
  let(:copy) { "/clean/copy" }
  let(:checks) { Hecks::Adapters::MainIntegration::Checks }

  def declare(row) = allow(Hecks::RustBuild::WorldRows).to receive(:row).with(copy, "main_verification").and_return(row)

  it "prefixes a command with the worker cap and the niceness the world sets" do
    declare(workers: 2, nice: 10)
    expect(described_class.prefix(copy)).to eq(%w[env PARALLEL_PROCESSOR_COUNT=2 nice -n 10])
  end

  it "leaves out what the line does not set" do
    declare(nice: 5)
    expect(described_class.prefix(copy)).to eq(%w[nice -n 5])
  end

  it "adds nothing for a checkout with no line" do
    declare({})
    expect(described_class.prefix(copy)).to eq([])
  end

  it "answers the worker cap, nil without a line" do
    declare(workers: 3)
    expect(described_class.workers(copy)).to eq(3)
  end

  it "is declared in the committed Tickets world" do
    root = File.expand_path("..", __dir__)
    row = Hecks::RustBuild::WorldRows.row(root, "main_verification")
    expect(row.values_at(:workers, :nice)).to all(be_a(Integer))
  end

  it "runs every check it ran before, each behind the prefix", :aggregate_failures do
    declare(workers: 2, nice: 10)
    all = checks.new(copy, [], shallow_off: true, impacted: ->(*) {}).all
    expect(all.map(&:first)).to eq(["quick gate", "impacted specs"])
    expect(all.first.last.first(4)).to eq(%w[env PARALLEL_PROCESSOR_COUNT=2 nice -n])
  end

  it "keeps the quick gate's own command after the prefix" do
    declare(workers: 2, nice: 10)
    argv = checks.new(copy).all.first.last
    gate = [*checks::RUNS_AS, checks::LAUNCHER, *checks::FIXED["quick gate"]]
    expect(argv.last(gate.size)).to eq(gate)
  end
end
