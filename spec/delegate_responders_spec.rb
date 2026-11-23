require "spec_helper"
require_relative "support/stand_in_claude"
require_relative "support/wakes_coder_helpers"
require_relative "support/question_answerer_helpers"
require_relative "support/responder_helpers"

# A stall fixer blocked on a question its stall already settled is answered by the false-stall
# responder, not by a seat's orchestrator run, and only once the responder was replayed against
# the lead's past answers of its family and switched on. A question that is the owner's is never
# its to answer.
RSpec.describe "a blocked run's question a fact decides" do
  include_context "with a stand-in claude"
  include WakesCoderHelpers
  include QuestionAnswererHelpers
  include ResponderHelpers

  let(:woken) { [] }
  let(:fixer) { "stall-agent-run-blocked-ad52223c" }

  prepend_before { @hecks = boot_hecks_in_memory }
  before { fake_runner(woken) }

  context "with the false-stall responder switched on after its replay matched" do
    before { switch_on("false-stall") }

    it "answers a fixer whose stall was already settled, taking no seat", :aggregate_failures do
      settle(fixer)
      orchestrator_blocked_on(fixer, "board fails to load in this checkout")
      expect(answerers(fixer)).to be_empty
      expect(open_questions).not_to include(fixer)
      expect(desk["seated"].to_i).to eq(0)
    end

    it "leaves a fixer whose stall is still open to a seat" do
      orchestrator_blocked_on(fixer, "board fails to load in this checkout")
      expect(answerers(fixer).size).to eq(1)
    end

    it "never answers a question that is the owner's" do
      settle(fixer)
      orchestrator_blocked_on(fixer, "[owner] Release the board fix?")
      expect(open_questions).not_to include(fixer)
    end

    it "answers no second question inside its spacing" do
      settle(fixer)
      orchestrator_blocked_on(fixer, "board fails to load in this checkout")
      expect(admit_refusal("false-stall", Time.now.to_i + 1)).to include("spacing")
    end
  end

  it "leaves a settled stall's question to a seat while the responder is not switched on" do
    declare("false-stall")
    settle(fixer)
    orchestrator_blocked_on(fixer, "board fails to load in this checkout")
    expect(answerers(fixer).size).to eq(1)
  end

  it "refuses to switch on a responder whose replay has not matched" do
    declare("false-stall")
    expect(switch_on_refusal("false-stall")).to include("replay")
  end
end
