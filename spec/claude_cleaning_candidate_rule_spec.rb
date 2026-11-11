# frozen_string_literal: true

require "spec_helper"
require "hecks/hecks/adapters/claude_cleaning"

# The rule that makes a listed session a candidate for removal: a finished-done run's session is
# one when the listing says `done`, or says `working` while its status is `idle` (the turn is over).
RSpec.describe Hecks::Adapters::ClaudeCleaning::CandidateRule do
  subject(:rule) { described_class.new(runs: runs, transcript: transcript) }

  let(:runs) { { "r1" => { status: "finished", condition: "done" } } }
  let(:transcript) { instance_double(Hecks::Adapters::ClaudeTranscript, taken_over?: false) }

  def entry(state, status = nil) = { "sessionId" => "s", "state" => state, "status" => status }.compact

  it "makes a done run's session listed done a candidate" do
    expect(rule.why_not(entry("done"), "r1")).to be_nil
  end

  it "makes a done run's session listed working while idle a candidate" do
    expect(rule.why_not(entry("working", "idle"), "r1")).to be_nil
  end

  it "keeps a done run's session listed working and busy, and names it" do
    expect(rule.why_not(entry("working", "busy"), "r1")).to eq("listed working, not done")
  end

  it "keeps a done run's session listed blocked even when idle" do
    expect(rule.why_not(entry("blocked", "idle"), "r1")).to eq("listed blocked, not done")
  end

  it "keeps a session no run holds, and names the rule" do
    expect(rule.why_not(entry("working", "idle"), nil)).to eq("no dispatched run holds it")
  end
end
