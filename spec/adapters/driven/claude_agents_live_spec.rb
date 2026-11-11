require "spec_helper"
require "fileutils"
require "tmpdir"
require "hecks/hecks/adapters/claude_agents"

# Builds a stand-in `claude agents` listing and a job file under a scratch directory.
module ClaudeAgentsLiveWorld
  def write_world(job_state, sessions)
    File.write(File.join(scratch, "claude"), "#!/bin/sh\ncat \"$(dirname \"$0\")/sessions.json\"\n")
    File.chmod(0o755, File.join(scratch, "claude"))
    FileUtils.mkdir_p(File.join(scratch, "jobs", "abc123"))
    File.write(File.join(scratch, "jobs", "abc123", "state.json"), JSON.generate(state: job_state))
    File.write(File.join(scratch, "sessions.json"), JSON.generate(sessions))
  end

  def read(job_state, *sessions)
    write_world(job_state, sessions)
    settings = { command: File.join(scratch, "claude"), jobs: File.join(scratch, "jobs"), settle: 0, projects: scratch }
    described_class.new(settings: settings)
                   .read_job(session: { value: "abc123" }, repo: { value: scratch }, agent: { value: "coder" })
  end
end

# A job that reads ended while the listing says the session still works or waits is reported with
# the listing's state beside it, so the bluebook can decline to record the run finished.
RSpec.describe Hecks::Adapters::ClaudeAgents, "#read_job live state" do
  include ClaudeAgentsLiveWorld

  let(:scratch) { File.realpath(Dir.mktmpdir("claude-agents-live")) }

  after { FileUtils.rm_rf(scratch) }

  it "keeps the job's done and reports a working listing" do
    expect(read("done", { id: "abc123", state: "working" })).to include(state: "done", live: "working")
  end

  it "keeps the job's done and reports a blocked listing" do
    expect(read("done", { id: "abc123", state: "blocked" })).to include(state: "done", live: "blocked")
  end

  it "reports a done listing for a session that really ended" do
    expect(read("done", { id: "abc123", state: "done" })).to include(state: "done", live: "done")
  end

  it "reports a stopped session as stopped" do
    expect(read("stopped", { id: "abc123", state: "stopped" })).to include(state: "stopped", live: "stopped")
  end

  it "reports no live state for an unlisted session" do
    expect(read("done", { id: "other", state: "working" })).to include(state: "done", live: "")
  end
end
