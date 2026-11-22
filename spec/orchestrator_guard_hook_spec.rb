# frozen_string_literal: true

require "spec_helper"
require "json"
require "digest"
require "open3"
require "tmpdir"

# The Bash guard hook, run against a scratch checkout whose `exe/hecks` is a stand-in: the stand-in
# writes the words it was called with and answers as each example says, so the hook's forwarding and
# its refusal when Hecks cannot answer are seen without booting Hecks.
RSpec.describe "the orchestrator guard hook" do
  let(:root) { File.expand_path("..", __dir__) }
  let(:dir) { Dir.mktmpdir("orchestrator_guard") }
  let(:agents) { File.join(dir, "lib/hecks/agents") }
  let(:rules) { File.join(dir, ".claude/hooks/guard_rules.json") }

  before do
    FileUtils.mkdir_p(File.join(dir, ".claude/hooks"))
    FileUtils.mkdir_p(File.join(dir, "exe"))
    FileUtils.cp(File.join(root, ".claude/hooks/orchestrator_guard.sh"), File.join(dir, ".claude/hooks"))
    File.write(File.join(dir, ".claude/hooks/guarded_roles"), "# Generated\norchestrator\n")
    FileUtils.mkdir_p(agents)
    File.write(File.join(agents, "agents.bluebook"), "domain Agents\n")
    project(roles: { orchestrator: [], coder: [] })
  end

  after { FileUtils.remove_entry(dir) }

  # Writes the rules file, current for the scratch agents bluebook unless `digest` says otherwise.
  def project(roles: { orchestrator: ["git status", "git branch"] }, digest: Digest::SHA256.hexdigest("domain Agents\n"))
    File.write(rules, JSON.generate(digest: digest, roles: roles))
  end

  def asked? = File.exist?(File.join(dir, "argv"))

  # Makes the stand-in launcher record its words, print `body` and exit with `code`.
  def launcher(body: "allowed", code: 0, pause: 0)
    path = File.join(dir, "exe/hecks")
    File.write(path, "#!/bin/sh\nprintf '%s\\n' \"$@\" > \"#{dir}/argv\"\nsleep #{pause}\n" \
                     "printf '%s\\n' '#{body}'\nexit #{code}\n")
    File.chmod(0o755, path)
  end

  # @return [Array(String, Integer)] what the hook wrote to stderr, and its exit status
  def hook(command, role: "orchestrator")
    input = JSON.generate(agent_type: role, session_id: "s1", tool_input: { command: command })
    env = { "CLAUDE_PROJECT_DIR" => dir, "HECKS_GUARD_LIMIT" => "1" }
    _out, err, status = Open3.capture3(env, File.join(dir, ".claude/hooks/orchestrator_guard.sh"), stdin_data: input)
    [err, status.exitstatus]
  end

  def unanswered = launcher(body: "[unknown_command] no such command", code: 2)

  it "forwards the query name, role, command, agent and session as separate words" do
    launcher
    hook("git status")
    expect(File.read(File.join(dir, "argv")).lines(chomp: true))
      .to eq(["agents", "Role.guard", "role.value=orchestrator", "command.value=git status", "agent.value=",
              "session.value=s1"])
  end

  it "lets an allowed command through" do
    launcher
    expect(hook("git status").last).to eq(0)
  end

  it "relays a refusal" do
    launcher(body: "orchestrator routes only: use the coder. Refused: cat x", code: 1)
    expect(hook("cat x")).to eq(["orchestrator routes only: use the coder. Refused: cat x\n", 2])
  end

  describe "when Hecks cannot answer" do
    before { unanswered }

    it "refuses a guarded role, naming the error", :aggregate_failures do
      err, status = hook("cat lib/x.rb")
      expect(status).to eq(2)
      expect(err).to include("[unknown_command] no such command", "Refused: cat lib/x.rb")
    end

    it "still lets a guarded role re-ask the guard and read git status", :aggregate_failures do
      expect(hook("exe/hecks agents Role.guard").last).to eq(0)
      expect(hook("git status").last).to eq(0)
    end

    it "lets a role with no routing rows through" do
      expect(hook("cat lib/x.rb", role: "coder").last).to eq(0)
    end

    it "counts every role as guarded when the list is missing" do
      File.delete(File.join(dir, ".claude/hooks/guarded_roles"))
      expect(hook("cat lib/x.rb", role: "coder").last).to eq(2)
    end
  end

  describe "with the projected rules file" do
    before do
      project
      launcher
    end

    it "decides a call that is exactly a git read row without asking the door", :aggregate_failures do
      expect(hook("git status").last).to eq(0)
      expect(asked?).to be(false)
    end

    it "lets a role the rules do not list through without asking the door", :aggregate_failures do
      expect(hook("cat lib/x.rb", role: "scout").last).to eq(0)
      expect(asked?).to be(false)
    end

    it "sends a git branch that makes a branch to the door" do
      hook("git branch newname")
      expect(asked?).to be(true)
    end

    it "sends a launcher call, which the script rule must note, to the door" do
      hook("exe/hecks agents Role.guard")
      expect(asked?).to be(true)
    end

    it "refuses a guarded role's call when the rules file is missing", :aggregate_failures do
      File.delete(rules)
      err, status = hook("git log")
      expect(status).to eq(2)
      expect(err).to include("guard_rules.json is missing", "project_agent_roles!")
      expect(asked?).to be(false)
    end

    it "refuses a guarded role's call when the rules file is stale", :aggregate_failures do
      project(digest: "0" * 64)
      err, status = hook("git log")
      expect(status).to eq(2)
      expect(err).to include("guard_rules.json is stale", "project_agent_roles!")
      expect(asked?).to be(false)
    end

    it "still lets a guarded role run the projection when the rules file is stale", :aggregate_failures do
      project(digest: "0" * 64)
      expect(hook("exe/hecks regeneration_run.project_agent_roles!").last).to eq(0)
      expect(hook("exe/hecks regeneration_run.project_agent_roles! --wait").last).to eq(0)
    end

    it "lets a role that is not guarded through when the rules file is stale" do
      project(digest: "0" * 64)
      expect(hook("cat lib/x.rb", role: "coder").last).to eq(0)
    end
  end

  it "refuses a guarded role when the guard takes longer than the limit" do
    launcher(pause: 3)
    expect(hook("cat lib/x.rb").first).to include("no answer in 1s")
  end

  it "lets a session with no role through" do
    unanswered
    expect(hook("cat lib/x.rb", role: "").last).to eq(0)
  end

  it "is executable in the checkout, since settings.json skips a hook that is not" do
    expect(File.executable?(File.join(root, ".claude/hooks/orchestrator_guard.sh"))).to be(true)
  end
end
