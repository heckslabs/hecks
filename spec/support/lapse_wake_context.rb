require_relative "stand_in_claude"
require_relative "wakes_coder_helpers"

# What the lapse wake specs drive: a review asked for long ago, so its limit has passed by the
# clock the sweep reads, and one sweep of the sessions. `asks: 1` is a review asked for the second
# time, the one a lapse ends; `asks: 0` is the first, which a sweep asks again.
module LapseWakeHelpers
  def request_long_ago(work, asks: 1)
    launch("agents", "PlanReview.request!", "run.value=r-#{work}", "work.value=#{work}", "hops.value=1",
           "role.value=architect", "repo.value=#{scratch}", "plan.value=review this plan as written", "now.value=1",
           "asks.value=#{asks}", "--wait")
  end

  def reviews_of(work)
    out, = launch("agents", "PlanReview.reviews")
    JSON.parse(out.to_s[/\[.*\]/m]).select { |row| row["work"] == work }
  end

  def sweep(key) = launch("agent_run.check_all!", "run.value=#{key}", "--wait")

  def waiting_past_limit(work, asks: 1)
    wait_as_coder(work)
    request_long_ago(work, asks: asks)
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
