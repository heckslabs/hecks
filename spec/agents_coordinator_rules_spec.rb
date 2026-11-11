require "spec_helper"
require_relative "support/coordinator_role_data"

# The coordinator's standing rules: each has a row with its reason and evidence, is named in the
# role file, and the owner-only ones are told to every coder in its brief.
RSpec.describe "the coordinator's standing rules" do
  include CoordinatorRoleData

  def coder_source = File.read(File.join(CoordinatorRoleData::ROOT, "lib/hecks/coder/coder.bluebook"))

  it "names every rule in the role file" do
    expect(role_rows("StandingRule").map { |row| role_file.include?("**#{row[:rule]}**") }).to all(be(true))
  end

  it "gives every rule a reason and its evidence" do
    expect(role_rows("StandingRule").map { |row| [row[:reason], row[:evidence]].none?(&:empty?) }).to all(be(true))
  end

  it "holds the nine rules" do
    names = %w[revert-first all-hands-on-red board-when-level report-when-green remove-when-pushed rely-on-events
               say-work-item-and-coder release-is-the-owners discard-is-the-owners]
    expect(role_rows("StandingRule").map { |row| row[:rule] }).to match_array(names)
  end

  it "tells every coder the question markers" do
    expect(coder_source).to include("[review] is a normal wait for a verdict")
  end

  it "keeps discard and release with the owner in a coder's brief", :aggregate_failures do
    expect(coder_source).to include("Landing.discard! is the owner's alone", "Release-Approved-By trailer")
  end
end
