require "spec_helper"
require "hecks/agents/adapters/routing_guard"

# The orchestrator's allowlist is data on the Agents bluebook's Role aggregate; the guard, the
# hook and the role file only read or forward it. Nothing here touches a live ledger or tap.
RSpec.describe "the orchestrator routing guard" do
  let(:root)  { InMemoryDomain::ROOT }
  let(:guard) { Hecks::Adapters::RoutingGuard.new }

  def verdict(command, role: "orchestrator") = guard.guard(role: { value: role }, command: { value: command })

  def refusal(command)
    verdict(command)
  rescue Hecks::Adapters::RoutingGuard::Refused => e
    e.message
  end

  def rows(table)
    bluebook = Hecks.describe(File.join(root, "lib/hecks/agents")).registry.bluebooks.fetch("Agents")
    role = bluebook.aggregates.find { |aggregate| aggregate.hecks_name == "Role" }
    role.value_objects.find { |object| object.hecks_name == table }.members
  end

  describe "the Role row" do
    it "carries the routing commands of the orchestrator", :aggregate_failures do
      patterns = rows("RoutingRule").map { |row| row[:pattern] }
      expect(patterns).to include("Work.*", "Dispatch.fill!", "SendTrain.board!", "PipelineBoard.snapshot")
      expect(patterns).to include("AgentRun.check_all!", "AgentRun.answer!", "AgentRun.tidy!", "Landing.retire!")
    end

    it "lets the orchestrator settle ended sessions, with a hint for the nearest refused shape", :aggregate_failures do
      expect(rows("RoutingRule").map { |row| row[:pattern] }).to include("Dispatch.settle!")
      expect(rows("RefusalHint").map { |row| row[:shape] }).to include("settle")
    end

    it "carries the no-work rule as data" do
      expect(rows("RoleRule").first[:rule]).to include("A claim is verified by a reviewer run, never by you")
    end
  end

  describe "a command on the list" do
    it "allows a launcher call of a listed verb" do
      expect(verdict("exe/hecks AgentRun.check_all!")).to eq(text: "allowed")
    end

    it "allows a wildcard aggregate behind its domain word" do
      expect(verdict("exe/hecks tickets Work.undone")).to eq(text: "allowed")
    end

    it "allows a listed verb with arguments" do
      expect(verdict("exe/hecks pipeline_board PipelineBoard.snapshot width.value=120")).to eq(text: "allowed")
    end
  end

  describe "a command off the list" do
    it "refuses a file read naming the role to use" do
      expect(refusal("cat lib/x.rb")).to include("orchestrator routes only: use the coder or reviewer role")
    end

    it "refuses a spec runner" do
      expect(refusal("bundle exec rspec spec/x_spec.rb")).to include("the coder role through Work.plan!/Dispatch")
    end

    it "refuses a search" do
      expect(refusal("grep -rn Role lib")).to include("a search is run there")
    end

    it "refuses an unlisted verb of the launcher" do
      expect(refusal("exe/hecks test_suite_run.run_spec_files! x")).to include("routes only")
    end

    it "refuses a listed verb chained to another command" do
      expect(refusal("exe/hecks AgentRun.check_all! && cat x")).to include("Refused:")
    end
  end

  describe "a read-only git or gh call" do
    %w[status log diff].each do |verb|
      it "allows git #{verb}" do
        expect(verdict("git #{verb} --stat")).to eq(text: "allowed")
      end
    end

    it "allows git worktree list" do
      expect(verdict("git worktree list")).to eq(text: "allowed")
    end

    it "allows git branch with a list flag" do
      expect(verdict("git branch --list")).to eq(text: "allowed")
    end

    it "allows gh pr view, pr list and run view", :aggregate_failures do
      ["gh pr view 12 --json state", "gh pr list", "gh run view 99"].each do |call|
        expect(verdict(call)).to eq(text: "allowed")
      end
    end

    it "allows Work.finish! and Work.undone", :aggregate_failures do
      expect(verdict("exe/hecks tickets Work.finish! to=x")).to eq(text: "allowed")
      expect(verdict("exe/hecks tickets Work.undone")).to eq(text: "allowed")
    end

    it "allows Operation.follow, so the orchestrator hears a run start or end without polling" do
      call = "exe/hecks Operation.follow domain.value=Hecks aggregate.value=AgentRun from_now=true wait=600"
      expect(verdict(call)).to eq(text: "allowed")
    end

    it "carries the Operation.follow row as data" do
      expect(rows("RoutingRule").map { |row| row[:pattern] }).to include("Operation.follow")
    end

    it "carries the shell rows and the flag rules as data", :aggregate_failures do
      expect(rows("RoutingRule").map { |row| row[:pattern] }).to include("git status", "gh pr view", "git worktree")
      expect(rows("ShellFlagRule").map { |row| row[:command] }).to include("git", "gh", "git branch")
    end
  end

  describe "a git verb the orchestrator may run" do
    %w[show fetch switch merge cherry-pick revert commit add tag worktree].each do |verb|
      it "allows git #{verb}" do
        expect(verdict("git #{verb} x")).to eq(text: "allowed")
      end
    end

    it "carries the verbs as RoutingRule rows", :aggregate_failures do
      patterns = rows("RoutingRule").map { |row| row[:pattern] }
      expect(patterns).to include("git show", "git fetch", "git commit", "git worktree", "git tag")
      expect(patterns).not_to include("git worktree list")
    end
  end

  describe "a git call that stays refused" do
    ["git push", "git push origin main", "git push --force", "git push -f origin x",
     "git push --force-with-lease", "git commit --no-verify -m x", "git commit -n -m x",
     "git commit --admin x", "git merge --no-verify x"].each do |call|
      it "refuses #{call}" do
        expect(refusal(call)).to include("routes only")
      end
    end

    it "refuses a force flag on an allowed verb", :aggregate_failures do
      expect(refusal("git fetch -f origin")).to include("routes only")
      expect(refusal("git worktree remove --force x")).to include("routes only")
    end

    it "refuses the verbs it leaves out", :aggregate_failures do
      %w[reset restore checkout stash rebase].each { |verb| expect(refusal("git #{verb} x")).to include("routes only") }
    end

    it "refuses an owner push override set in the command", :aggregate_failures do
      expect(refusal("HECKS_OWNER_PUSH=why git push")).to include("routes only")
      expect(refusal("export HECKS_OWNER_PUSH=why")).to include("routes only")
    end

    it "refuses a global option or alias that reaches push", :aggregate_failures do
      ["git -c alias.p=push p", "git -C . push", "git --git-dir=x push", "git p"].each do |call|
        expect(refusal(call)).to include("routes only")
      end
    end
  end

  describe "a git or gh write" do
    it "still refuses git push, naming the train" do
      expect(refusal("git push origin main")).to include("SendTrain.board!")
    end

    it "refuses branch deletion and branch creation through git branch", :aggregate_failures do
      ["git branch -D x", "git branch newname"].each do |call|
        expect(refusal(call)).to include("routes only")
      end
    end

    it "refuses gh pr merge and a gh read that opens a browser", :aggregate_failures do
      expect(refusal("gh pr merge 3")).to include("routes only")
      expect(refusal("gh pr view 3 --web")).to include("routes only")
    end

    it "refuses a flag that writes a file", :aggregate_failures do
      expect(refusal("git log --output=x")).to include("routes only")
      expect(refusal("git diff --ext-diff")).to include("routes only")
    end

    it "refuses a git read chained to another command" do
      expect(refusal("git status && rm x")).to include("Refused:")
    end
  end

  it "does not guard a role with no routing rows" do
    expect(verdict("cat lib/x.rb", role: "coder")).to eq(text: "allowed")
  end

  describe "the hook" do
    let(:hook) { File.read(File.join(root, ".claude/hooks/orchestrator_guard.sh")) }

    it "only forwards to the Role.guard query" do
      expect(hook).to include("exe/hecks agents Role.guard")
    end

    it "holds no verb of the routing list" do
      expect(hook).not_to match(/Work\.|Dispatch\.|SendTrain|Landing\./)
    end

    it "is registered as a PreToolUse hook for Bash" do
      settings = JSON.parse(File.read(File.join(root, ".claude/settings.json")))
      expect(settings.dig("hooks", "PreToolUse", 0, "matcher")).to eq("Bash")
    end
  end

  describe "the role file" do
    let(:file) { File.read(File.join(root, ".claude/agents/orchestrator.md")) }

    it "states the rule held on the Role row" do
      expect(file).to include(rows("RoleRule").first[:rule])
    end

    it "ends every reply with the board snapshot" do
      expect(file).to include("PipelineBoard.snapshot width.value=120")
    end
  end
end
