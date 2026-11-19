require "spec_helper"
require_relative "../lib/hecks/hecks/adapters/reviewer_judgment"

# The reviewer's role text as the Role aggregate's RoleFile rows declare it: told its tier, it
# reads the diff and the Work item's brief, runs the behaviors and the model check, and closes on
# one word.
RSpec.describe "the reviewer role's rows" do
  def rows
    bluebook = Hecks.describe(File.join(InMemoryDomain::ROOT, "lib/hecks/agents")).registry.bluebooks.fetch("Agents")
    role = bluebook.aggregates.find { |aggregate| aggregate.hecks_name == "Role" }
    role.value_objects.find { |object| object.hecks_name == "RoleFile" }.members.to_h { |row| [row[:role], row] }
  end

  def reviewer = rows.fetch("reviewer").values_at(:purpose, :steps, :handback).join("\n")

  it "tells the reviewer its tier, FULL when the request names none" do
    expect(reviewer).to include("FULL or VERIFY-ONLY", "A request that names no tier is FULL")
  end

  it "reads the diff and the brief, never the coder's report" do
    expect(reviewer).to include("Work.show work=", "Never read the coder's report or its transcript")
  end

  it "runs the behaviors and the model check of every touched domain on the FULL tier" do
    expect(reviewer).to include("Operation.run_behaviors!", "ModelCheckRun.model_check!")
  end

  it "closes on one of the four words the reader reads" do
    expect(reviewer).to include(*Hecks::Adapters::ReviewerJudgment::WORDS.map { |word| "`#{word}`" })
  end

  it "leaves the review to the landing: the orchestrator does not send a finished branch to the reviewer" do
    expect(rows.fetch("orchestrator")[:steps]).not_to include("A finished branch goes to the reviewer")
  end
end
