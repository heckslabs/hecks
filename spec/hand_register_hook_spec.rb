require "spec_helper"
require "json"
require "tmpdir"
require "open3"

# The SessionStart hook registers a session with no AgentRun through the launcher, and leaves one
# that has a run alone.
RSpec.describe ".claude/hooks/hand_register.sh" do
  let(:hook) { File.expand_path("../.claude/hooks/hand_register.sh", __dir__) }
  let(:dir) { Dir.mktmpdir }

  after { FileUtils.remove_entry(dir) }

  def launcher(running:)
    FileUtils.mkdir_p("#{dir}/exe")
    File.write("#{dir}/exe/hecks",
               "#!/bin/sh\necho \"$@\" >> #{dir}/calls\n[ \"$1\" = agent_run.running ] && echo '#{running}'\nexit 0\n")
    FileUtils.chmod(0o755, "#{dir}/exe/hecks")
  end

  def start(session, type = "")
    payload = JSON.generate(session_id: session, agent_type: type)
    Open3.capture2({ "HECKS_CHECKOUT" => dir }, hook, stdin_data: payload)
    File.read("#{dir}/calls")
  end

  it "registers a session that has no run under hand-<short id>" do
    launcher(running: "")
    expect(start("abcdef12-3456")).to include("HandRun.register! run.value=hand-abcdef12 session.value=abcdef12-3456")
  end

  it "registers the orchestrator seat as orchestrator" do
    launcher(running: "")
    expect(start("abcdef12-3456", "orchestrator-owner")).to include("run.value=orchestrator")
  end

  it "leaves a session that has a run alone" do
    launcher(running: "abcdef12-3456")
    expect(start("abcdef12-3456")).not_to include("HandRun.register!")
  end
end
