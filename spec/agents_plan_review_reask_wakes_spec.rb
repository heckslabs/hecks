require "spec_helper"
require_relative "support/lapse_wake_context"

# A sweep over a review asked for once, whose limit passed, ends it and asks the architect again as
# a review of its own: the coder is not woken, and only the second window lapses.
RSpec.describe "a plan review asked again before it lapses" do
  include_context "with coders waiting on plan reviews"

  def swept_first_ask(work)
    waiting_past_limit(work, asks: 0)
    sweep("s-#{work}")
  end

  it "keeps the first review and adds a second asked review", :aggregate_failures do
    swept_first_ask("a-one")
    expect(reviews_of("a-one").map { |row| row["asks"] }).to contain_exactly(0, 1)
    expect(woken).to be_empty
  end
end
