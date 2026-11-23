# frozen_string_literal: true

require "hecks/hecks/adapters/claude_agents"
require "hecks/hecks/adapters/claude_resumption"

# A session listed done whose process still stands is stopped before it is resumed, so the resume
# wakes it under its own id and never starts a copy.
RSpec.describe Hecks::Adapters::ClaudeResumption do
  let(:shell) { instance_double(Hecks::Adapters::Shell) }
  let(:result) { Struct.new(:ok?, :out, :err).new(true, "backgrounded · abcdef1\n", "") }
  let(:commands) { [] }

  def wake(entry)
    allow(shell).to receive(:capture) { |*args, **| commands << args && result }
    described_class.new("claude", shell, patience: 0).call("abcdef1", entry, "go", env: {}, chdir: Dir.pwd)
  end

  def stopped? = commands.any? { |words| words[1] == "stop" }

  it "stops a session listed done whose process still stands" do
    wake("id" => "abcdef1", "sessionId" => "full-id", "state" => "done", "pid" => Process.pid)
    expect(stopped?).to be(true)
  end

  it "does not stop a session listed done whose process is gone" do
    wake("id" => "abcdef1", "sessionId" => "full-id", "state" => "done", "pid" => 2_999_999)
    expect(stopped?).to be(false)
  end

  it "keeps the listed state for a listing with no pid" do
    wake("id" => "abcdef1", "sessionId" => "full-id", "state" => "done")
    expect(stopped?).to be(false)
  end

  it "resumes by the full session id" do
    wake("id" => "abcdef1", "sessionId" => "full-id", "state" => "stopped")
    expect(commands.last).to include("--resume", "full-id")
  end
end
