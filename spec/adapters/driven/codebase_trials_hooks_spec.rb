# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "hecks/hecks/adapters/codebase/gate"
require "hecks/hecks/adapters/codebase/spec_files"

# Helpers for the gate and the spec batches recording their trials into a temporary log.
module CodebaseTrialsHooksHelpers
  CODEBASE = Hecks::Adapters::Codebase

  # A trial record under `dir`.
  def trials(dir)
    CODEBASE::Trials.new(ledger: CODEBASE::Trials::Ledger.new(File.join(dir, "trials.jsonl")), load: -> { 1.0 })
  end

  # Runs the quick gate with the tool answering `answer`, and answers its report.
  def gate(dir, answer)
    child = instance_double(CODEBASE::RubyChild, answer: answer)
    allow(CODEBASE::RubyChild).to receive(:new).and_return(child)
    tree = instance_double(CODEBASE::Tree, root: dir)
    CODEBASE::Gate.call("gate", { stage: "quick", only: "rubocop" }, tree, trials: trials(dir))[:report][:value]
  end

  # The rows of a kind the log under `dir` holds.
  def recorded(dir, kind) = CODEBASE::Trials::Ledger.new(File.join(dir, "trials.jsonl")).read(kind)

  # Runs one spec file through a runner that answers it passed, and answers the report.
  def batch(dir)
    File.write(File.join(dir, "a_spec.rb"), "")
    runner = instance_double(CODEBASE::TestRunner, outcome: [0, "1 example, 0 failures"])
    tree = instance_double(CODEBASE::Tree, root: dir)
    CODEBASE::SpecFiles.new(tree, runner: runner, trials: trials(dir)).run(files: "a_spec.rb")
  end
end

RSpec.describe "Trials recorded by the gate and the spec batches" do
  include CodebaseTrialsHooksHelpers

  let(:dir) { Dir.mktmpdir("trials-hooks") }

  after { FileUtils.rm_rf(dir) }

  it "adds the quick gate's pass^k lines to its report" do
    expect(gate(dir, "[gate quick] green: rubocop")).to end_with("pass^3: no subject has 2 runs yet")
  end

  it "records each check of a quick gate run as a trial of gate-quick" do
    gate(dir, "[gate quick] green: rubocop")
    expect(recorded(dir, "gate-quick").size).to eq(1)
  end

  it "keeps the spec batch's totals last, after its pass^k lines" do
    expect(batch(dir)).to match(/pass\^3: no subject has 2 runs yet\n\n1 example, 0 failures\z/)
  end
end
