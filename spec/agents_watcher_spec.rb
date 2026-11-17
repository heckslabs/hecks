require "spec_helper"
require_relative "support/plan_review_limit_helpers"

# A watcher is a declared watch of a pipeline component: it lapses and opens a new window while
# attempts remain, and only its give-up raises the events that file and wake.
RSpec.describe "the Agents watcher" do
  include PlanReviewLimitHelpers

  before { boot_agents }

  def watcher = Hecks::Agents::Watcher

  def declare(at: 1000, cap: 2, key: "watch-a")
    watcher.declare!(watcher: { value: key }, component: { value: "landing" }, opens: { value: "LandingOpened" },
                     closes: { value: "BranchLanded" }, timeout_seconds: { value: 100 },
                     max_attempts: { value: cap }, now: { value: at })
  end

  def refused(pattern) = raise_error(Hecks::Runtime::GivenNotMet, pattern)

  def exhausted = declare.lapse!(now: { value: 1100 }).lapse!(now: { value: 1200 })

  it "starts watching with no attempt counted" do
    expect(declare.attempts.value).to eq(0)
  end

  it "refuses a lapse inside its window, by name" do
    expect { declare.lapse!(now: { value: 1099 }) }.to refused(/window has passed/)
  end

  it "counts one attempt and opens a new window when a lapse comes" do
    expect(declare.lapse!(now: { value: 1100 }).opened_at.value).to eq(1100)
  end

  it "refuses to give up while attempts remain, by name" do
    expect { declare.give_up!(now: { value: 5000 }) }.to refused(/no attempt remains/)
  end

  it "refuses another lapse once attempts are used, by name" do
    expect { exhausted.lapse!(now: { value: 1300 }) }.to refused(/attempts remain/)
  end

  it "gives up once the last window passes" do
    expect(exhausted.give_up!(now: { value: 1300 }).status).to eq("given_up")
  end

  it "refuses to give up before the last window passes, by name" do
    expect { exhausted.give_up!(now: { value: 1250 }) }.to refused(/window has passed/)
  end

  it "settles when a closing event comes" do
    expect(declare.observe!(closed_by: { value: "BranchLanded" }, now: { value: 1050 }).status).to eq("settled")
  end

  it "refuses a lapse after it settled, by name" do
    settled = declare.observe!(closed_by: { value: "BranchLanded" }, now: { value: 1050 })
    expect { settled.lapse!(now: { value: 5000 }) }.to refused(/has not ended/)
  end

  it "refuses a settle after it gave up" do
    gave_up = exhausted.give_up!(now: { value: 1300 })
    expect { gave_up.observe!(closed_by: { value: "x" }, now: { value: 1301 }) }.to raise_error(StandardError)
  end

  it "refuses a key that does not start with watch-" do
    expect { declare(key: "stall") }.to raise_error(StandardError)
  end
end
