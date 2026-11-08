require "spec_helper"

# The pruner's role file, read by section.
module PrunerRoleFile
  PATH = File.join(InMemoryDomain::ROOT, ".claude/agents/pruner.md")

  def role = File.read(PATH)
  def steps = role[/## How to work(.*?)## What you hand back/m, 1]
  def report = role[/## What you hand back(.*?)## Handoffs/m, 1]

  def pinned_roles
    bluebook = Hecks.describe(File.join(InMemoryDomain::ROOT, "lib/hecks/agents")).registry.bluebooks.fetch("Agents")
    role = bluebook.aggregates.find { |aggregate| aggregate.hecks_name == "Role" }
    role.value_objects.find { |object| object.hecks_name == "PinnedRole" }.members.map { |row| row[:role] }
  end
end

# The pruner role file carries the rules that keep a session from being removed by mistake: the
# pins in `~/.claude/jobs/pins.json`, the roles the board pins (read from the world's `agent_roles`
# line, never a list of the role file's own), and the AgentRun ledger as the one reading of
# "finished", since a session that is `done` between turns is idle, not finished. The report lists
# every skipped session by id with the rule that kept it, the pinned ones first.
RSpec.describe "the pruner role file" do
  include PrunerRoleFile

  describe "its pinned roles" do
    it "reads them from the bluebook's PinnedRole rows, not a list of its own", :aggregate_failures do
      expect(steps).to include("`PinnedRole` rows of the `Role` aggregate in `lib/hecks/agents/agents.bluebook`")
      expect(steps).to include("A pinned role's session is never removed")
    end

    it "keeps the owner's pinned sessions from the pins file until AgentRun carries the fact" do
      expect(steps).to match(%r{until AgentRun carries a pinned fact.*~/\.claude/jobs/pins\.json}m)
    end

    it "declares the orchestrator as a pinned role in the bluebook" do
      expect(pinned_roles).to include("orchestrator")
    end
  end

  describe "its skip rules" do
    it "reads the roles the board pins from the world's agent_roles line", :aggregate_failures do
      expect(steps).to include("`agent_roles` line in `lib/hecks/hecks/hecks.world`")
      expect(steps).to include("never from a list of your own")
      expect(steps).to include("Never remove a session that holds a pinned role")
    end

    it "keeps the orchestrator above all" do
      expect(steps).to include("the orchestrator above all")
    end

    it "reads finished from the AgentRun ledger, not from the session list", :aggregate_failures do
      expect(steps).to include("exe/hecks agent_run.tidyable")
      expect(steps).to include("finished only when its run is in the finished list with condition `done` or `stopped`")
    end

    it "says idle is not finished unless unpinned and done or stopped in the ledger" do
      expect(steps).to include("Idle is not finished unless the session is unpinned **and** its run is done or stopped")
    end

    it "keeps a session that has no run in the ledger" do
      expect(steps).to include("A session with no run in the ledger is kept")
    end

    it "still never discards unpushed work" do
      expect(steps).to include("Never pass `--discard-unpushed`")
    end
  end

  describe "its report" do
    it "reports the skipped sessions by id with the rule that kept them", :aggregate_failures do
      expect(report).to include("**Skipped:** each session kept, by id, with the rule that kept it")
      expect(report).to include("Every pinned session you saw is listed here by id")
    end
  end
end
