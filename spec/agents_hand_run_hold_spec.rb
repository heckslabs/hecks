require "spec_helper"
require "hecks/agents/adapters/hand_run_hold"
require "hecks/agents/adapters/sweeping"
require "hecks/hecks/adapters/claude_cleaning/plain_sweep"
require "hecks/hecks/adapters/claude_cleaning/keep_window"
require "hecks/hecks/adapters/claude_cleaning/reap_facts"
require_relative "support/agents_message_helpers"

# A registered hand run holds its session and its worktree: no sweep removes or retires either until
# `HandRun.end!`, while an unregistered session that is done is still reaped.
RSpec.describe Hecks::Adapters::HandRunHold do
  include AgentsMessageHelpers

  let(:hold) { described_class.new(registry: @agents_runtime.registry) }

  before do
    boot_messages
    register_hand(run: "coder", session: "5e55aaaa-full", role: "coder", checkout: "/work/coder")
  end

  it "names the run holding a registered session" do
    expect(hold.session("5e55aaaa")).to eq("coder")
  end

  it "names the run holding a registered checkout" do
    expect(hold.checkout("/work/coder")).to eq("coder")
  end

  it "holds nothing for a session no hand run registered" do
    expect(hold.session("ffffffff")).to be_nil
  end

  it "holds nothing once the hand run ends" do
    Hecks::Agents::HandRun.find("coder").end!
    expect(hold.rows).to be_empty
  end

  it "holds nothing for a replaced registration" do
    register_hand(run: "coder", session: "newer-full", role: "coder", checkout: "/work/newer")
    expect(hold.rows.map { |row| row[:session] }).to eq(["newer-full"])
  end

  describe "the plain sweep" do
    let(:removed) { [] }

    def sweep(entry)
      window = Hecks::Adapters::ClaudeCleaning::KeepWindow.new(owner_hours: 0, helper_minutes: 0, jobs: nil, pinned: [])
      allow(window).to receive(:pin).and_return(nil)
      Hecks::Adapters::ClaudeCleaning::PlainSweep.new(
        window: window, now: -> { 10**9 }, transcript: double(worktree: "", modified_at: 0), hold: hold,
        remove: ->(id) { (removed << id) && nil }
      ).call([entry], [])
    end

    it "keeps a registered hand run's done session" do
      sweep({ "id" => "5e55aaaa", "sessionId" => "5e55aaaa-full", "name" => "c", "state" => "done" })
      expect(removed).to be_empty
    end

    it "still reaps an unregistered done session" do
      sweep({ "id" => "ffffffff", "sessionId" => "ffffffff-full", "name" => "x", "state" => "done" })
      expect(removed).to eq(["ffffffff"])
    end
  end

  describe "the worktree sweep" do
    it "keeps a registered hand run's worktree whatever main holds" do
      entry = Struct.new(:path, :branch, :tip).new("/work/coder", "coder", "abc")
      allow(Hecks::Adapters::Sweeping::Worktrees::Listing).to receive(:new).and_return(double(linked: [entry]))
      worktrees = Hecks::Adapters::Sweeping::Worktrees.new(shell: double, repo: "/repo", hold: hold)
      expect(worktrees.lines).to include("keeper  /work/coder  held by hand run coder")
    end
  end

  describe "the signalbox reap facts" do
    def facts
      sources = Hecks::Adapters::ClaudeCleaning::ReapFacts::Sources.new(
        window: double(pin: nil), transcript: double(taken_over?: false, worktree: ""),
        jobs: double(launched_by: ""), hold: hold
      )
      Hecks::Adapters::ClaudeCleaning::ReapFacts.new(sources, {})
    end

    it "reports a registered hand run's session as open" do
      row = { id: "5e55aaaa", session: "5e55aaaa-full", kind: "finished", idle_minutes: 9, live: "no" }
      expect(facts.session(row, "p")[:open]).to eq("yes")
    end

    it "reports a copy at a registered checkout as open" do
      row = { branch: "coder", path: "/work/coder", idle_minutes: 9, unsaved: 0, landed: "yes", held: "no" }
      expect(facts.copy(row, "p")[:open]).to eq("yes")
    end
  end
end
