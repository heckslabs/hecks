# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "hecks/hecks/adapters/codebase/trials"

# Helpers for the trial record: a log under a temporary directory and runs recorded into it.
module CodebaseTrialsHelpers
  TRIALS = Hecks::Adapters::Codebase::Trials

  # A trial record whose log lives under `dir`, its load and clock fixed.
  def trials(dir, load: 2.0)
    TRIALS.new(ledger: TRIALS::Ledger.new(File.join(dir, "trials.jsonl")), clock: -> { Time.utc(2026, 11, 18) },
               load: -> { load }, cpus: 4)
  end

  # Records the outcomes, one run each, of one spec file, and answers the last run's lines.
  def runs(record, outcomes)
    outcomes.map { |passed| record.record("spec", "spec/a_spec.rb" => passed) }.last
  end
end

RSpec.describe Hecks::Adapters::Codebase::Trials do
  include CodebaseTrialsHelpers

  let(:dir) { Dir.mktmpdir("trials") }

  after { FileUtils.rm_rf(dir) }

  it "says pass^3 is about 0.42 for a spec that passed three of four runs" do
    expect(runs(trials(dir), [true, false, true, true])).to include("pass^3: 0.42 over 1 subject(s)")
  end

  it "names a spec that has failed a run, with its passes and its pass^3" do
    expect(runs(trials(dir), [true, false])).to include("spec/a_spec.rb: 1 of 2 passed, pass^3 0.12")
  end

  it "counts no subject with only one run in the batch's figure" do
    expect(runs(trials(dir), [true])).to eq("pass^3: no subject has 2 runs yet")
  end

  it "keeps each result with the run's load and cpu count", :aggregate_failures do
    runs(trials(dir, load: 6.5), [false])
    row = JSON.parse(File.read(File.join(dir, "trials.jsonl")))
    expect(row).to include("kind" => "spec", "subject" => "spec/a_spec.rb", "passed" => false, "load" => 6.5, "cpus" => 4)
  end

  it "records nothing for a run that had no subject" do
    expect(trials(dir).record("spec", {})).to be_nil
  end

  it "turns a log it cannot write into one line instead of refusing the run" do
    File.write(File.join(dir, "blocked"), "")
    record = described_class.new(ledger: described_class::Ledger.new(File.join(dir, "blocked", "trials.jsonl")))
    expect(record.record("spec", "spec/a_spec.rb" => true)).to start_with("trials not recorded:")
  end
end
