require "spec_helper"
require "fileutils"
require "json"
require "open3"
require "tmpdir"
require "hecks/hecks/adapters/session_hooks"

# The check a stopping session runs on its own run, executed through a shell as Claude Code runs
# it, against a stand-in launcher that records each call. A stop whose job state has not changed
# since the last check boots nothing; one whose state changed runs the check once.
RSpec.describe Hecks::Adapters::SessionHooks do
  let(:scratch) { File.realpath(Dir.mktmpdir("session-hooks-check")) }
  let(:launcher) { File.join(scratch, "hecks") }
  let(:hooks) do
    described_class.new(launcher: launcher, jobs: "#{scratch}/jobs", seen: "#{scratch}/seen", settle: 0)
  end

  before do
    FileUtils.mkdir_p("#{scratch}/jobs/abc")
    File.write(launcher, "#!/bin/sh\necho \"$@\" >> #{scratch}/calls\nexit #{status}\n")
    FileUtils.chmod("+x", launcher)
    write_state("working")
  end

  after { FileUtils.rm_rf(scratch) }

  let(:status) { 0 }

  def write_state(state) = File.write("#{scratch}/jobs/abc/state.json", JSON.generate("state" => state))

  def calls = File.exist?("#{scratch}/calls") ? File.readlines("#{scratch}/calls").size : 0

  def check_command(event) = hooks.for("fix-it").fetch(event).first.fetch("hooks").last.fetch("command")

  def stop(input = %({"session_id": "abc"}), event: "SessionEnd")
    Open3.capture3("/bin/sh", "-c", check_command(event), stdin_data: input)
  end

  it "checks the run once when its state is new" do
    stop

    expect(calls).to eq(1)
  end

  it "boots nothing when the state has not changed since the last check" do
    stop
    stop

    expect(calls).to eq(1)
  end

  it "checks again once the state changed" do
    stop
    write_state("done")
    stop

    expect(calls).to eq(2)
  end

  it "checks on a Stop as it does on a SessionEnd" do
    stop(event: "Stop")
    stop(event: "Stop")

    expect(calls).to eq(1)
  end

  it "checks when the hook input names no session" do
    stop("{}")
    stop("{}")

    expect(calls).to eq(2)
  end

  it "checks when the session has no state file" do
    stop(%({"session_id": "nobody"}))

    expect(calls).to eq(1)
  end

  context "when the check fails" do
    let(:status) { 1 }

    it "checks again at the next stop with the same state" do
      stop
      stop

      expect(calls).to eq(2)
    end
  end
end
