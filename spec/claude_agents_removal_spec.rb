# frozen_string_literal: true

require "spec_helper"
require "hecks/hecks/adapters/claude_agents"

# `AgentRun.Tidy` asks the adapter to review a finished run's session and to remove it: a session
# only the pipeline answered is removed, an owner-typed turn keeps it by name, and a session whose
# worktree still stands is left with the reason `claude rm` gave.
RSpec.describe Hecks::Adapters::ClaudeAgents::Removal do
  # Answers every `claude` call with one refusal and keeps the calls.
  let(:shell_class) do
    Struct.new(:calls) do
      def capture(*args)
        calls << args
        Struct.new(:err) { def ok? = false }.new("kept abc: its worktree is still at /w/x")
      end
    end
  end
  let(:host_class) do
    Class.new do
      include Hecks::Adapters::ClaudeAgents::Removal

      def initialize(transcript, shell, listed: true)
        @transcript = transcript
        entry = listed ? { "sessionId" => "full-id", "state" => "done" } : nil
        @listing = Struct.new(:entry) { def find(_id) = entry }.new(entry)
        @shell = shell
        @command = "claude"
        @reaping = Struct.new(:x) { def facts(*) = { unmerged: false } }.new
      end

      def plain(value) = value[:value]
      def listed(_id) = { "sessionId" => "full-id" }
      def worktree_of(_full) = ""
    end
  end
  let(:shell) { shell_class.new([]) }
  let(:failure) { Hecks::Adapters::ConsoleCapture::Failure }

  def host(reading, listed: true)
    host_class.new(instance_double(Hecks::Adapters::ClaudeTranscript, reading: reading), shell, listed: listed)
  end

  def review(reading) = host(reading).review(session: { value: "abc" })

  def remove = host({}).remove(session: { value: "abc" })

  it "does not keep a session only the pipeline answered" do
    expect(review(state: :read, person_turns: 0)).to include(taken_over: false, note: "nobody replied")
  end

  it "keeps a session the owner typed into, naming it" do
    expect(review(state: :read, person_turns: 2))
      .to include(taken_over: true, note: "a person replied (2 turns after the brief)")
  end

  it "answers a session the listing does not hold as gone, without a claude call", :aggregate_failures do
    expect(host({}, listed: false).review(session: { value: "abc" })).to include(listed: false, gone_at: Hash)
    expect(shell.calls).to be_empty
  end

  it "names a transcript that is missing" do
    expect(review(state: :missing, person_turns: 0)).to include(taken_over: true, note: "the transcript is missing")
  end

  it "names a transcript that cannot be read" do
    expect(review(state: :unreadable, person_turns: 0))
      .to include(taken_over: true, note: "the transcript cannot be read")
  end

  it "leaves a session whose worktree still stands, naming where" do
    expect { remove }.to raise_error(failure, %r{session kept: its worktree is still at /w/x})
  end

  it "does not stop a session whose worktree still stands", :aggregate_failures do
    expect { remove }.to raise_error(failure)
    expect(shell.calls).to eq([%w[claude rm abc]])
  end

  it "says the state the listing shows now" do
    expect(review(state: :read, person_turns: 0)).to include(live: "done")
  end

  it "stops a session with claude stop, naming what a refusal said", :aggregate_failures do
    expect { host({}).stop_session(session: { value: "abc" }) }.to raise_error(failure, /claude stop abc refused: kept abc/)
    expect(shell.calls).to eq([%w[claude stop abc]])
  end
end
