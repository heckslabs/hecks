require "spec_helper"
require "hecks/vocabulary"

# The full spec suite is a CI-only check. Owner decision: nobody runs the full suite locally, so
# the local pre-push stage holds no check marked `runs_in: "ci"`, and the quick stage keeps its
# checks. These specs read the Vocabulary gate rows the decision is declared in.
RSpec.describe "the local gate scope" do
  def stage_checks(name)
    Hecks::Vocabulary.rows("GateStage").find { |row| row["name"] == name }.fetch("checks").split(",")
  end

  def check_row(name)
    Hecks::Vocabulary.rows("GateCheck").find { |row| row["name"] == name }
  end

  it "keeps the full suite out of the local pre_push stage" do
    expect(stage_checks("pre_push")).not_to include("rspec")
  end

  it "declares the full suite as a check that runs in CI" do
    expect(check_row("rspec")).to include("runs_in" => "ci")
  end

  it "does not attest the full suite from a local push, since no local stage ran it" do
    hook = File.read(File.join(InMemoryDomain::ROOT, ".githooks/pre-push"))

    expect(hook[/ATTEST_CHECKS="[^"]*"/]).not_to include("rspec")
  end

  it "holds the full suite in a stage of its own, which no local stage lists" do
    expect(stage_checks("ci_suite")).to eq(["rspec"])
  end

  it "keeps every quick-stage check local", :aggregate_failures do
    %w[shape_ledger rubocop comment_style comment_blocks secret_output adapter_words io_spec_list].each do |name|
      expect(stage_checks("quick")).to include(name)
    end
  end
end
