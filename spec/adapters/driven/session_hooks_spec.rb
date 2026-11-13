require "spec_helper"
require "fileutils"
require "open3"
require "tmpdir"
require "hecks/hecks/adapters/session_hooks"

# The `Stop` command that asks whether a turn may end, run through a shell as Claude Code runs it,
# against a stand-in launcher that records its arguments and answers as the example says. Only a
# turn the launcher reports held is refused, with the refusal on stderr and exit 2.
RSpec.describe Hecks::Adapters::SessionHooks do
  let(:scratch) { File.realpath(Dir.mktmpdir("session-hooks")) }
  let(:launcher) { File.join(scratch, "hecks") }
  let(:hooks) { described_class.new(launcher: launcher) }

  after { FileUtils.rm_rf(scratch) }

  def stand_in(stderr:, status:)
    File.write(launcher, "#!/bin/sh\necho \"$@\" > #{scratch}/asked\necho '{}'\necho '#{stderr}' >&2\nexit #{status}\n")
    FileUtils.chmod("+x", launcher)
  end

  def held = stand_in(stderr: %([hecks] a notice\nTurn ended in the failure state "held": Commit, then submit.), status: 1)

  # Runs the hook as Claude Code does, with the hook's input on stdin.
  def run_hook(input = "{}") = Open3.capture3("/bin/sh", "-c", hooks.turn_end("fix-it"), stdin_data: input)

  def asked = File.read(File.join(scratch, "asked")).strip

  it "asks the Coder bluebook whether the run's turn may end" do
    stand_in(stderr: "", status: 0)
    run_hook

    expect(asked).to eq("coder Turn.end! run.value=fix-it again.value=false --wait")
  end

  it "says the turn is ending again when Claude Code says a hook already refused this stop" do
    stand_in(stderr: "", status: 0)
    run_hook(%({"session_id":"abc","stop_hook_active":true}))

    expect(asked).to include("again.value=true")
  end

  it "refuses a held turn with only the refusal on stderr and exit 2", :aggregate_failures do
    held
    out, err, status = run_hook

    expect(status.exitstatus).to eq(2)
    expect([out, err]).to eq(["", %(Turn ended in the failure state "held": Commit, then submit.\n)])
  end

  it "lets the turn end when the launcher reports any other failure", :aggregate_failures do
    stand_in(stderr: "cannot open Hecks: no such world", status: 1)
    _out, err, status = run_hook

    expect(status.exitstatus).to eq(0)
    expect(err).to be_empty
  end

  it "lets the turn end when the bluebook ends it" do
    stand_in(stderr: "", status: 0)

    expect(run_hook.last.exitstatus).to eq(0)
  end

  it "puts the turn's question between the inbox and the run's check in the Stop hook" do
    commands = hooks.for("fix-it").fetch("Stop").first.fetch("hooks").map { |hook| hook.fetch("command") }

    expect(commands[1]).to eq(hooks.turn_end("fix-it"))
  end
end
