require "spec_helper"
require "hecks/hecks/adapters/git_rehearsal"

# How a red spec file is named in a rehearsal's report.
RSpec.describe Hecks::Adapters::GitRehearsal::Impacted::SpecRun::Outcome do
  def outcome(*failures) = described_class.new("spec/a_spec.rb", false, failures)

  it "names every failing example" do
    expect(outcome("./spec/a_spec.rb:3 # x", "./spec/a_spec.rb:9 # y").line)
      .to eq("failing spec: ./spec/a_spec.rb:3 # x, ./spec/a_spec.rb:9 # y")
  end

  it "names the file when no example was read" do
    expect(outcome.line).to eq("failing spec: spec/a_spec.rb")
  end
end
