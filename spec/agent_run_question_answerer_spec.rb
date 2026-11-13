require "spec_helper"
require_relative "support/stand_in_claude"
require_relative "support/wakes_coder_helpers"
require_relative "support/question_answerer_helpers"

# A coder blocked on a question for the orchestrator gets one orchestrator run that answers it, at
# most two such runs at once; an owner's question starts none and is left for the owner.
RSpec.describe "a coder blocked on a question" do
  include_context "with a stand-in claude"
  include WakesCoderHelpers
  include QuestionAnswererHelpers

  let(:woken) { [] }

  # A runtime per example: the desk's seats are the state under test.
  before do
    @hecks = boot_hecks_in_memory
    fake_runner(woken)
  end

  it "starts one orchestrator run for the question", :aggregate_failures do
    blocked_on("q-one", "[choose] A or B?")
    expect(answerers("q-one").size).to eq(1)
    expect(answerers("q-one").first["agent"]).to eq("orchestrator")
  end

  it "starts no second run when the same block is read again" do
    blocked_on("q-again", "[confirm] Go on?")
    launch("agent_run.check!", "to=q-again", "--wait")
    expect(answerers("q-again").size).to eq(1)
  end

  it "frees the answerer's seat once the coder is answered" do
    blocked_on("q-freed", "[retry] Try again?")
    answer("q-freed")
    expect(desk["seated"]).to eq(0)
  end

  it "holds at most two orchestrator runs at once" do
    %w[q-cap-1 q-cap-2 q-cap-3].each { |work| blocked_on(work, "[choose] A or B?") }
    expect(answerers.count { |row| row["work"].to_s.start_with?("q-cap-") }).to eq(2)
  end

  it "leaves an owner's question to the owner", :aggregate_failures do
    blocked_on("q-owner", "[owner] Resume dispatch_roll_forward?")
    expect(answerers("q-owner")).to be_empty
    expect(runs_woken).to be_empty
  end

  it "ends the answerer when it closes with its word" do
    blocked_on("q-ends", "[choose] A or B?")
    answerer_closes(answerers("q-ends").first["run"], "Told it to take A. answered")
    expect(answerers("q-ends")).to be_empty
  end

  it "treats a review wait as no question" do
    blocked_on("q-review", "[review] waiting on the architect for q-review")
    expect(answerers("q-review")).to be_empty
  end
end
