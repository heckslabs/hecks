require "spec_helper"
require_relative "support/stand_in_claude"
require_relative "support/wakes_coder_helpers"

# What the Answer-or-Record spec reads: how many verdicts the architect's rule has answered, and
# an architect run dispatched with no review asked for it.
module RecordAndAnswerHelpers
  def answers
    @hecks.registry.reaction_log.count { |row| row[:policy] == "RecordTheArchitectsVerdict" && row[:delivered] }
  end

  # A review asked for and closed with its verdict, and the count of answers once it closed.
  def closed_review(work)
    request_review(work)
    architect_closes(work, "Verdict: sound with changes. Revise.")
    answers
  end

  def unasked(work)
    launch("agent_run.dispatch!", "run.value=r-#{work}", "repo.value=#{scratch}", "brief.value=plan",
           "agent.value=architect", "work.value=#{work}", "--wait")
  end
end

# A review that exists is answered on every job read that judges its verdict, and a review no
# request made is recorded from the verdict, so `Answer` and `Record` never both miss one. The
# verdict is recorded once: a later read of the same run leaves the review as it is.
RSpec.describe "the Agents plan review recorded by Answer or Record" do
  include_context "with a stand-in claude"
  include WakesCoderHelpers
  include RecordAndAnswerHelpers

  before(:all) { @hecks = boot_hecks_in_memory }

  before { fake_runner([]) }

  it "records the verdict of an asked review whose architect went idle" do
    request_review("a-idle")
    architect_idles("a-idle", "Verdict: sound. Build it.")
    expect(review_of("a-idle")["verdict"]).to eq("sound")
  end

  it "records the verdict of an asked review once, across a second read", :aggregate_failures do
    answered = closed_review("a-twice")
    launch("agent_run.check!", "to=r-a-twice", "--wait")
    expect(review_of("a-twice")["verdict"]).to eq("changes")
    expect(answers).to eq(answered)
  end

  it "records the verdict of a run no review was asked for" do
    unasked("a-unasked")
    architect_idles("a-unasked", "Verdict: rethink. Start over.")
    expect(review_of("a-unasked")["verdict"]).to eq("rethink")
  end
end
