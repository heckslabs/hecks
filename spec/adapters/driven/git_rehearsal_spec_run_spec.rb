require "spec_helper"
require "tmpdir"
require "fileutils"
require "json"
require "hecks/hecks/adapters/git_rehearsal"

# How one spec file's launcher answer is read, and which specs cannot run here.
# How one spec file's launcher answer is read.
RSpec.describe Hecks::Adapters::GitRehearsal::Impacted::SpecRun do
  Said = Struct.new(:out, :err, :ok?, :exit_code)

  def answer(report) = Said.new("noise\n#{JSON.generate("state" => report)}", "", true, 0)

  def refused(report) = Said.new("noise\n#{JSON.generate("state" => report)}", "", false, 1)

  def outcome(said) = described_class.new(->(*, **) { said }).call("/tmp", "spec/a_spec.rb")

  it "passes a green report" do
    expect(outcome(answer("report" => "3 examples, 0 failures")).passed).to be(true)
  end

  it "fails a refused run and names the failing example" do
    refusal = "1 example, 1 failure\n\nFailed examples:\n\nrspec ./spec/a_spec.rb:7 # a fails\n"
    expect(outcome(refused("refusal" => refusal)).failures).to eq(["./spec/a_spec.rb:7 # a fails"])
  end

  it "passes a completed run whose exit was non-zero for reactions the spec's domains refused" do
    said = refused("status" => "completed", "report" => "18 examples, 0 failures")
    expect(outcome(said).passed).to be(true)
  end

  it "fails a run that loaded nothing" do
    said = answer("report" => "0 examples, 0 failures, 1 error occurred outside of examples")
    expect(outcome(said).passed).to be(false)
  end
end
