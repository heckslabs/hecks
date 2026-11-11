require "spec_helper"
require_relative "support/stand_in_claude"
require_relative "support/wakes_coder_helpers"

# A recorded plan verdict resumes the coder run waiting on that Work item and no other.
RSpec.describe "a recorded plan verdict waking the coder waiting for it" do
  include_context "with a stand-in claude"
  include WakesCoderHelpers

  before(:all) { @hecks = boot_hecks_in_memory }

  let(:woken) { [] }

  before { fake_runner(woken) }

  def review(work, verdict)
    request_review(work)
    architect_closes(work, verdict)
  end

  it "resumes the coder run keyed by the reviewed Work item, with the findings", :aggregate_failures do
    wait_as_coder("w-one")
    review("w-one", "Verdict: sound. Build it.")
    expect(runs_woken).to eq(["w-one"])
    expect(woken.first[:answer].to_s).to include("Build it.")
  end

  it "resumes the coder when the architect said its verdict and went idle without exiting" do
    wait_as_coder("w-idle")
    request_review("w-idle")
    architect_idles("w-idle", "Verdict: sound. Build it.")
    expect(runs_woken).to eq(["w-idle"])
  end

  it "wakes no coder while the architect is still busy" do
    wait_as_coder("w-busy")
    request_review("w-busy")
    architect_idles("w-busy", "Verdict: sound", status: "busy")
    expect(runs_woken).to be_empty
  end

  it "wakes no coder waiting on a different Work item" do
    wait_as_coder("w-a")
    review("w-b", "Verdict: changes. Revise.")
    expect(runs_woken).to be_empty
  end
end
