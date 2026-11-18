require "spec_helper"
require_relative "support/stand_in_claude"
require_relative "support/wakes_coder_helpers"
require_relative "support/judged_once_helpers"

# A judge's verdict ends the judge's run, so an architect whose session went idle with its verdict
# said, and whose job never read done, is not read, judged and sent to the coder again at every
# check. Scratch state only: a stand-in `claude` and a Memory runtime.
RSpec.describe "a judged verdict ending the judge's run" do
  include_context "with a stand-in claude"
  include WakesCoderHelpers
  include JudgedOnceHelpers

  before(:all) { @hecks = boot_hecks_in_memory }

  let(:woken) { [] }

  before { fake_runner(woken) }

  # Agents keeps its verdicts in Memory and each sweep is a process of its own, so a second reading
  # of the architect's job would judge the verdict afresh and answer the coder with it again.
  it "finishes the architect's run, so the next sweep does not read its job again", :aggregate_failures do
    idle_architect_checked("w-once")
    read = architect_reads
    sweep
    expect(architect_reads - read).to eq(0)
    expect(architect_running?).to be(false)
  end

  it "fires no Finish for a verdict judged with no run of its own" do
    finished = count("SessionFinished")
    launch("agents", "Verdict.judge!", "run.value=j-none", "work.value=w-none", "role.value=architect",
           "answer.value=sound", "--wait")
    expect(count("SessionFinished")).to eq(finished)
  end
end
