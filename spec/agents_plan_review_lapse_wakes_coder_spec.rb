require "spec_helper"
require_relative "support/stand_in_claude"
require_relative "support/wakes_coder_helpers"

# What the lapse wake spec drives: a review asked for long ago, so its limit has passed by the
# clock the sweep reads, and one sweep of the sessions.
module LapseWakeHelpers
  def request_long_ago(work)
    launch("agents", "PlanReview.request!", "run.value=r-#{work}", "work.value=#{work}", "hops.value=1",
           "role.value=architect", "repo.value=#{scratch}", "plan.value=plan", "now.value=1", "--wait")
  end

  def sweep(key) = launch("agent_run.check_all!", "run.value=#{key}", "--wait")

  def waiting_past_limit(work)
    wait_as_coder(work)
    request_long_ago(work)
  end

  def lapsed_by_a_sweep(work)
    waiting_past_limit(work)
    sweep("s-#{work}")
  end
end

RSpec.shared_context "with coders waiting on plan reviews" do
  include_context "with a stand-in claude"
  include WakesCoderHelpers
  include LapseWakeHelpers

  before(:all) { @hecks = boot_hecks_in_memory }

  let(:woken) { [] }

  before { fake_runner(woken) }
end

# A sweep of the sessions lapses the review whose time limit passed with no verdict, and the coder
# waiting on its Work item is woken with the reason, once. A review inside its limit is left open,
# and a verdict that comes after the lapse does not wake the coder again.
RSpec.describe "a lapsed plan review waking the coder waiting for it" do
  include_context "with coders waiting on plan reviews"

  it "ends the overdue review with the reason", :aggregate_failures do
    lapsed_by_a_sweep("l-one")
    expect(review_of("l-one")["verdict"]).to be_nil
    expect(review_of("l-one")["reason"].to_s).to include("time limit")
  end

  it "answers the coder run with the reason, telling it to build", :aggregate_failures do
    lapsed_by_a_sweep("l-two")
    expect(runs_woken).to eq(["l-two"])
    expect(woken.first[:answer].to_s).to include("build your plan")
  end

  it "leaves a review inside its limit open", :aggregate_failures do
    wait_as_coder("l-three")
    request_review("l-three")
    sweep("s-three")
    expect(review_of("l-three")["reason"]).to be_nil
    expect(woken).to be_empty
  end

  it "wakes the coder once across a second sweep and a late verdict", :aggregate_failures do
    waiting_past_limit("l-four")
    2.times { |turn| sweep("s-four-#{turn}") }
    architect_closes("l-four", "Verdict: rethink. Start over.")
    expect(runs_woken).to eq(["l-four"])
    expect(review_of("l-four")["verdict"]).to be_nil
  end
end
