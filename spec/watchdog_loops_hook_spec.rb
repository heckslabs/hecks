# frozen_string_literal: true

require "spec_helper"
require "json"
require "open3"
require "tmpdir"

# A pinned session that starts again is told its loops by the SessionStart hook, from the rows
# the watchdog wrote, and the hook leaves the stamp the watchdog reads; any other session is
# told nothing more than its inbox watch.
RSpec.describe "a pinned session re-creates its loops on start" do
  let(:dir) { Dir.mktmpdir("watchdog_hook") }
  let(:dev) { File.join(dir, "dev") }
  let(:session) { "bbbb1111-2222-3333-4444-555555555555" }
  let(:loops) { { "ORCHESTRATOR" => [{ "kind" => "cron", "schedule" => "7,37 * * * *", "prompt" => "watch pass" }] } }

  before do
    FileUtils.mkdir_p([File.join(dir, "bin"), File.join(dir, ".claude"), File.join(dev, "watchdog")])
    FileUtils.cp_r(File.join(File.expand_path("..", __dir__), ".claude/hooks"), File.join(dir, ".claude"))
    File.write(File.join(dev, "watchdog", "loops.json"), JSON.generate(loops))
  end

  after { FileUtils.remove_entry(dir) }

  def listing(name)
    listed = JSON.generate([{ "sessionId" => session, "name" => name }])
    File.write(File.join(dir, "bin", "claude"), "#!/bin/sh\necho '#{listed}'\n")
    File.chmod(0o755, File.join(dir, "bin", "claude"))
  end

  def start_context
    env = { "CLAUDE_PROJECT_DIR" => dir, "HECKS_DEV_DIR" => dev, "PATH" => "#{dir}/bin:#{ENV.fetch("PATH")}" }
    out, = Open3.capture3(env, File.join(dir, ".claude/hooks/session_inbox_watch.sh"),
                          stdin_data: JSON.generate(session_id: session))
    JSON.parse(out).dig("hookSpecificOutput", "additionalContext")
  end

  it "names the loops of the pinned session and stamps that it did", :aggregate_failures do
    listing("ORCHESTRATOR")
    expect(start_context).to include("pinned session ORCHESTRATOR", "cron [7,37 * * * *]: watch pass")
    expect(File).to exist(File.join(dev, "watchdog", "armed", "ORCHESTRATOR"))
  end

  it "says nothing of loops to a session that is not pinned" do
    listing("some coder")
    expect(start_context).not_to include("loops")
  end
end
