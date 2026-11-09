require "spec_helper"
require "hecks/hecks/adapters/git_rehearsal"

# What a rehearsal says of the CI checks it ran and the ones it did not.
RSpec.describe Hecks::Adapters::GitRehearsal::Coverage do
  def line(scope) = described_class.new(scope).line

  it "names the checks a quick rehearsal ran in part" do
    expect(line("quick")).to include("ran in part: checks;")
  end

  it "names the spec check as run on impacted files in a deep rehearsal" do
    expect(line("deep")).to include("ran in part: checks, rspec (impacted files only);")
  end

  it "names the checks it did not run" do
    expect(line("deep")).to include("not run: rspec_postgres_io", "rspec_rust_host", "rspec_fuzzing")
  end

  it "does not claim a green CI and points at the early CI draft" do
    expect(line("quick")).to include("green here is not green CI", "EarlyCi")
  end

  it "is a passing stage of the scope's run" do
    result = Hecks::Adapters::GitRehearsal::Stages.new(Dir.pwd, scope: "quick").coverage_result
    expect(result.to_h).to include(name: "ci coverage", passed: true)
  end
end
