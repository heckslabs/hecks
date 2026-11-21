# frozen_string_literal: true

require "spec_helper"
require "json"
require "open3"
require "tmpdir"

# The Bash guard hook for a hand-started session: it has no `agent_type`, so it takes its role
# from its seat file and asks the guard of the checkout the hook lives in. The checkout's
# `exe/hecks` is a stand-in that records the words it was called with.
RSpec.describe "the guard hook for a seated hand-started session" do
  let(:root) { File.expand_path("..", __dir__) }
  let(:dir) { Dir.mktmpdir("seat_checkout") }
  let(:seats) { Dir.mktmpdir("seats") }
  let(:elsewhere) { Dir.mktmpdir("elsewhere") }

  before do
    FileUtils.mkdir_p([File.join(dir, ".claude/hooks"), File.join(dir, "exe")])
    FileUtils.cp(File.join(root, ".claude/hooks/orchestrator_guard.sh"), File.join(dir, ".claude/hooks"))
    File.write(File.join(dir, ".claude/hooks/guarded_roles"), "# Generated\norchestrator\n")
    stand_in = File.join(dir, "exe/hecks")
    File.write(stand_in, ["#!/bin/sh", "printf '%s\\n' \"$@\" > \"#{dir}/argv\"",
                          "echo 'orchestrator routes only: use Fleet.topic'", "exit 1", ""].join("\n"))
    File.chmod(0o755, stand_in)
  end

  after { [dir, seats, elsewhere].each { |path| FileUtils.remove_entry(path) } }

  # @return [Array(String, Integer)] stderr and exit status, started outside a checkout
  def seated(command, session: "hand1", type: nil)
    input = JSON.generate({ agent_type: type, session_id: session, tool_input: { command: command } }.compact)
    env = { "CLAUDE_PROJECT_DIR" => elsewhere, "HECKS_SEATS_DIR" => seats }
    hook = File.join(dir, ".claude/hooks/orchestrator_guard.sh")
    _out, err, status = Open3.capture3(env, hook, stdin_data: input)
    [err, status.exitstatus]
  end

  def seat(role) = File.write(File.join(seats, "hand1"), "#{role}\n")

  it "refuses a script with the verb hint", :aggregate_failures do
    seat("orchestrator")
    err, status = seated("sqlite3 x.db .tables")
    expect(status).to eq(2)
    expect(err).to include("use Fleet.topic")
  end

  it "asks the guard of the checkout the hook lives in with the seat's role" do
    seat("orchestrator")
    seated("ruby x.rb")
    expect(File.read(File.join(dir, "argv"))).to include("role.value=orchestrator")
  end

  it "leaves a session with no seat unguarded" do
    expect(seated("sqlite3 x.db .tables", session: "owner1").last).to eq(0)
  end

  it "runs a claude session with no seat normally, without asking the guard", :aggregate_failures do
    expect(seated("sqlite3 x.db .tables", type: "claude").last).to eq(0)
    expect(File.exist?(File.join(dir, "argv"))).to be(false)
  end

  it "refuses a claude session holding the orchestrator seat, from any directory", :aggregate_failures do
    seat("orchestrator")
    err, status = seated("ruby x.rb", type: "claude")
    expect([status, err]).to match([2, include("use Fleet.topic")])
  end

  it "lets a claude session run in a checkout whose list is missing" do
    FileUtils.rm(File.join(dir, ".claude/hooks/guarded_roles"))
    expect(seated("ls", type: "claude").last).to eq(0)
  end
end
