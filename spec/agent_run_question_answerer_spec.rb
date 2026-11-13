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

  # A runtime per example: the desk's seats are the state under test. Booted ahead of the
  # stand-in's own hook, which stubs a class the boot loads.
  prepend_before { @hecks = boot_hecks_in_memory }
  before { fake_runner(woken) }

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

  it "records the end of a run that asked no question with nothing refused" do
    wait_as_coder("q-none")
    expect(run_ends("q-none").last).to eq(0)
  end

  it "closes a seated question when its run ends", :aggregate_failures do
    blocked_on("q-seated-end", "[choose] A or B?")
    run_ends("q-seated-end")
    expect(open_questions).not_to include("q-seated-end")
    expect(desk["seated"]).to eq(0)
  end

  it "drops a question that found no seat when its run ends", :aggregate_failures do
    %w[q-full-1 q-full-2 q-asked-end].each { |work| blocked_on(work, "[choose] A or B?") }
    run_ends("q-asked-end")
    expect(open_questions).to contain_exactly("q-full-1", "q-full-2")
    expect(desk["seated"]).to eq(2)
  end

  it "treats a review wait as no question" do
    blocked_on("q-review", "[review] waiting on the architect for q-review")
    expect(answerers("q-review")).to be_empty
  end
end
