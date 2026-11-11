require "spec_helper"
require "fileutils"
require "tmpdir"
require "hecks/hecks/adapters/claude_agents"

# `claude agents` lists a session that finished its turn as idle while its job still reads
# `working`. The job read reports the listed status beside the true state and decides nothing.
RSpec.describe Hecks::Adapters::ClaudeAgents, "#read_job listed status" do
  let(:scratch) { File.realpath(Dir.mktmpdir("claude-agents-idle")) }
  let(:stand_in) { File.join(scratch, "claude") }
  let(:jobs) { File.join(scratch, "jobs") }
  let(:adapter) { described_class.new(settings: { command: stand_in, jobs: jobs, settle: 0, projects: scratch }) }

  before do
    File.write(stand_in, "#!/bin/sh\ncat \"$(dirname \"$0\")/sessions.json\"\n")
    File.chmod(0o755, stand_in)
    FileUtils.mkdir_p(File.join(jobs, "abc123"))
    File.write(File.join(jobs, "abc123", "state.json"), JSON.generate(state: "working", output: { result: "Verdict: sound" }))
  end

  after { FileUtils.rm_rf(scratch) }

  def listed(*sessions) = File.write(File.join(scratch, "sessions.json"), JSON.generate(sessions))

  def read = adapter.read_job(session: { value: "abc123" }, repo: { value: scratch }, agent: { value: "architect" })

  it "reports an idle session as listed idle, with the job's own state and verdict", :aggregate_failures do
    listed({ id: "abc123", status: "idle", state: "working" })

    expect(read).to include(listed: "idle", state: "working", verdict: "sound")
  end

  it "reports a busy session as listed busy" do
    listed({ id: "abc123", status: "busy", state: "working" })

    expect(read).to include(listed: "busy")
  end

  it "reports nothing for a session the listing does not hold" do
    listed({ id: "other", status: "idle" })

    expect(read).to include(listed: "")
  end

  it "reports nothing when the sessions cannot be listed" do
    File.write(stand_in, "#!/bin/sh\nexit 1\n")

    expect(read).to include(listed: "", state: "working")
  end
end
