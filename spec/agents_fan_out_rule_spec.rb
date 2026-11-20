require "spec_helper"

# Every role that does pipeline work says, as data, that it fans out where the work is independent:
# a `fan-out-where-independent` StandingRule row, and a `## Fan-out` section in its RoleFile row.
# The roles that read or build carry a typed subagent tool; the orchestrator fans out as runs and
# carries none.
RSpec.describe "the Role aggregate's fan-out rows" do
  subject(:role) do
    bluebook = Hecks.describe(File.join(InMemoryDomain::ROOT, "lib/hecks/agents")).registry.bluebooks.fetch("Agents")
    bluebook.aggregates.find { |aggregate| aggregate.hecks_name == "Role" }
  end

  let(:members) { ->(name) { role.value_objects.find { |object| object.hecks_name == name }.members } }
  let(:files) { members.call("RoleFile").to_h { |row| [row[:role], row] } }
  let(:subagents) do
    { "planner" => "Agent(planner)", "reviewer" => "Agent(reviewer)",
      "architect" => "Agent(architect)", "coder" => "Agent(Explore)" }
  end

  it "holds a fan-out-where-independent rule for each working role" do
    ruled = members.call("StandingRule").select { |row| row[:rule] == "fan-out-where-independent" }.map { |row| row[:role] }
    expect(ruled).to match_array(%w[planner orchestrator architect coder reviewer])
  end

  it "gives each reading or building role a subagent tool of a type that keeps its write limits" do
    expect(subagents.to_h { |name, _| [name, files.fetch(name)[:tools].split(", ").last] }).to eq(subagents)
  end

  it "gives the orchestrator no subagent tool, since its fan-out is runs" do
    expect(files.fetch("orchestrator")[:tools]).not_to include("Agent")
  end

  it "says the fan-out in words in every working role's file" do
    said = files.slice(*subagents.keys).transform_values { |row| row[:rules].include?("## Fan-out") }
    expect(said.values).to all(be(true))
  end
end
