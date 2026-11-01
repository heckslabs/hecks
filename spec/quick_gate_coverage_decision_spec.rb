require "spec_helper"

# A language word with no fuzzer coverage decision is caught by the quick gate, the check run
# before every commit, and not first by the pre-push fuzzing stage.
RSpec.describe "the quick gate's coverage decision check" do
  def stage(name) = Hecks::Vocabulary.rows("GateStage").find { |row| row["name"] == name }

  def check(name) = Hecks::Vocabulary.rows("GateCheck").find { |row| row["name"] == name }

  it "is listed in the quick stage" do
    expect(stage("quick")["checks"].split(",")).to include("meta_domain_coverage")
  end

  it "runs the meta-domain coverage spec under its fuzzing tag" do
    expect(check("meta_domain_coverage")["argv"]).to end_with("spec/fuzzing/meta_domain_coverage_spec.rb --tag fuzzing")
  end
end
