require "spec_helper"
require "stringio"
require "hecks/vocabulary"
require "hecks/tools/agent_roles"
require_relative "support/role_file_slices"

# The Vocabulary rows, the projection and the scratch world the role gate checks read.
module RoleGateChecks
  ROW = { role: "scout", description: "Looks ahead.", tools: "Read", model: "sonnet", purpose: "You scout.",
          steps: "1. **Look.** Go.", rules: "", handback: "What you found." }.freeze

  def check_row(name) = Hecks::Vocabulary.rows("GateCheck").find { |check| check["name"] == name }
  def quick = Hecks::Vocabulary.rows("GateStage").find { |stage| stage["name"] == "quick" }["checks"].split(",")
  def tool(*argv) = Hecks::Tools::AgentRoles.main(argv, rows: [ROW], out: @dir)

  def hushed
    streams = [$stderr, $stdout]
    $stderr = $stdout = StringIO.new
    yield
  ensure
    $stderr, $stdout = streams
  end

  def world(roles)
    File.join(@dir, "scratch.world").tap do |path|
      File.write(path, %(Hecks.world "Scratch" do\n  agent_roles "PipelineBoard", roles: "#{roles}"\nend\n))
    end
  end
end

# The two quick-stage checks that keep `.claude/agents` and the world's role list in step with the
# `RoleFile` rows: `role_files` compares the projected files, so a hand edit fails the push, and
# `role_world_list` compares the world's `agent_roles` line with the rows' role names. Each runs
# here against scratch rows and a scratch directory.
RSpec.describe "the role gate checks" do
  include RoleFileSlices
  include RoleGateChecks

  scratch_directory :dir, "role_gate"

  it "runs both checks in the quick stage" do
    expect(quick).to include("role_files", "role_world_list")
  end

  it "runs the projection's own compare as role_files" do
    expect(check_row("role_files")["argv"]).to include("project_agent_roles! check.value=true")
  end

  it "runs the world-list example as role_world_list" do
    expect(check_row("role_world_list")["script"]).to include("loads one row for each role the world pins")
  end

  it "passes role_files on files as the rows project them" do
    expect(hushed { tool && tool("--check") }).to eq(0)
  end

  it "fails role_files on a file edited by hand" do
    hushed { tool }
    File.write(File.join(@dir, "scout.md"), "edited\n", mode: "a")
    expect(hushed { tool("--check") }).to eq(1)
  end

  it "matches a world list naming every row's role" do
    expect(world_roles(world("scout,planner"))).to match_array(%w[scout planner])
  end

  it "finds a role missing from the world list" do
    expect(%w[scout planner] - world_roles(world("planner"))).to eq(["scout"])
  end
end
