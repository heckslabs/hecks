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
end
