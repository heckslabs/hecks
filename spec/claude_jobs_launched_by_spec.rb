require "spec_helper"
require "fileutils"
require "json"
require "tmpdir"
require "hecks/hecks/adapters/claude_jobs"

# Writes one job's `state.json`, its `respawnFlags` shaped as a dispatched release manager's are:
# `--agent`, then `--settings` with the caller in `env` beside the inbox hooks, then `--model`.
module LaunchedByJobs
  FLAGS = ["--agent", "release_manager", "--settings", nil, "--model", "claude-sonnet-5-5"].freeze

  def job(text)
    FileUtils.mkdir_p(File.join(dir, "723f5fc0"))
    File.write(File.join(dir, "723f5fc0", "state.json"), text)
  end

  def flags(settings)
    JSON.generate(state: "done", respawnFlags: FLAGS.map { |flag| flag || settings })
  end

  def dispatched = JSON.generate(env: { HECKS_CALLER: "release_manager:p-walk" }, hooks: { Stop: [] })
end

# The caller name the pipeline gives a session it launches, read from the job in a temporary
# jobs directory.
RSpec.describe Hecks::Adapters::ClaudeJobs, "#launched_by" do
  include LaunchedByJobs

  let(:dir) { Dir.mktmpdir("claude-jobs-launched") }
  let(:jobs) { described_class.new(directory: dir) }

  after { FileUtils.rm_rf(dir) }

  it "reads the caller name a dispatched session's settings carry" do
    job(flags(dispatched))
    expect(jobs.launched_by("723f5fc0")).to eq("release_manager:p-walk")
  end

  it "reads none for a session started by hand, whose job keeps no settings" do
    job(JSON.generate(state: "done", template: "claude", respawnFlags: []))
    expect(jobs.launched_by("723f5fc0")).to eq("")
  end

  it "reads none for settings that name no caller" do
    job(flags(JSON.generate(hooks: { Stop: [] })))
    expect(jobs.launched_by("723f5fc0")).to eq("")
  end

  it "reads none for a job whose state cannot be read" do
    job("{not json")
    expect(jobs.launched_by("723f5fc0")).to eq("")
  end

  it "reads none for a session with no job" do
    expect(jobs.launched_by("00000000")).to eq("")
  end
end
