require "spec_helper"
require_relative "support/stand_in_claude"
require_relative "support/wakes_coder_helpers"

# A coder that begins waiting on a Work item after its review was refused at request time is
# reminded: the wait's start (`ReviewAwaited`) reaches the review of that Work item, which ended
# just before with no verdict.
RSpec.describe "a coder waiting after its review was refused at request" do
  include_context "with a stand-in claude"
  include WakesCoderHelpers

  before(:all) { @hecks = boot_hecks_in_memory }

  let(:woken) { [] }

  before { fake_runner(woken) }

  def begin_waiting(work) = launch("agent_run.await!", "run.value=#{work}", "--wait")

  it "reminds a review refused at request, whose wait began after it ended" do
    wait_as_coder("m-one")
    request_in_missing_repo("m-one")
    expect(review_of("m-one")["reminded_at"]).to be_positive
  end

  it "does not remind the review of another Work item" do
    wait_as_coder("m-two")
    wait_as_coder("m-three")
    request_review("m-two")
    begin_waiting("m-three")
    expect(review_of("m-two")["reminded_at"].to_i).to eq(0)
  end
end
