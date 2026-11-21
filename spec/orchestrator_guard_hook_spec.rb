# frozen_string_literal: true

require "spec_helper"
require "json"
require "open3"
require "tmpdir"

# The Bash guard hook, run against a scratch checkout whose `exe/hecks` is a stand-in: the stand-in
# writes the words it was called with and answers as each example says, so the hook's forwarding and
# its refusal when Hecks cannot answer are seen without booting Hecks.
RSpec.describe "the orchestrator guard hook" do
  let(:root) { File.expand_path("..", __dir__) }
  let(:dir) { Dir.mktmpdir("orchestrator_guard") }

  before do
    FileUtils.mkdir_p(File.join(dir, ".claude/hooks"))
    FileUtils.mkdir_p(File.join(dir, "exe"))
    FileUtils.cp(File.join(root, ".claude/hooks/orchestrator_guard.sh"), File.join(dir, ".claude/hooks"))
    File.write(File.join(dir, ".claude/hooks/guarded_roles"), "# Generated\norchestrator\n")
  end

  after { FileUtils.remove_entry(dir) }

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

  describe "a hand-started session with a seat" do
    let(:seats) { Dir.mktmpdir("seats") }
    let(:elsewhere) { Dir.mktmpdir("elsewhere") }

    before { launcher(body: "orchestrator routes only: use Fleet.topic. Refused: x", code: 1) }

    after do
      FileUtils.remove_entry(seats)
      FileUtils.remove_entry(elsewhere)
    end

    # The hook as a session with no `agent_type` runs it, started in a directory that is no checkout.
    def seated(command, session: "hand1")
      input = JSON.generate(session_id: session, tool_input: { command: command })
      env = { "CLAUDE_PROJECT_DIR" => elsewhere, "HECKS_SEATS_DIR" => seats }
      _out, err, status = Open3.capture3(env, File.join(dir, ".claude/hooks/orchestrator_guard.sh"), stdin_data: input)
      [err, status.exitstatus]
    end

    it "is refused with the verb hint, from outside the checkout", :aggregate_failures do
      File.write(File.join(seats, "hand1"), "orchestrator\n")
      err, status = seated("sqlite3 x.db .tables")
      expect(status).to eq(2)
      expect(err).to include("use Fleet.topic")
    end

    it "asks the guard in the checkout the hook lives in" do
      File.write(File.join(seats, "hand1"), "orchestrator\n")
      seated("ruby x.rb")
      expect(File.read(File.join(dir, "argv"))).to include("role.value=orchestrator")
    end

    it "leaves a session with no seat unguarded" do
      expect(seated("sqlite3 x.db .tables", session: "owner1").last).to eq(0)
    end
  end
end
