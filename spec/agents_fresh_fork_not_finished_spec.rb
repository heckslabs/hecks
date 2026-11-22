require "spec_helper"
require_relative "support/stand_in_claude"
require_relative "support/wakes_coder_helpers"
require_relative "support/judged_once_helpers"
require_relative "support/fresh_fork_helpers"

# A fresh fork's job state is its parent's copy (done, "starting…") until the fork writes its own,
# so a coder the listing shows busy is never recorded finished by that copy. Scratch state only:
# a stand-in `claude` and a Memory runtime.
RSpec.describe "a freshly forked coder session" do
  include_context "with a stand-in claude"
  include WakesCoderHelpers
  include JudgedOnceHelpers
  include FreshForkHelpers

  before(:all) { @hecks = boot_hecks_in_memory }

  let(:woken) { [] }

  before { fake_runner(woken) }

  it "is not recorded finished while the listing shows it busy" do
    expect(finishes_after_check("w-fork-busy", listing: "busy")).to eq(0)
  end

  it "is recorded finished when the listing shows it idle" do
    expect(finishes_after_check("w-fork-idle", listing: "idle")).to eq(1)
  end

  it "is recorded finished when the listing cannot say, as a doubt never keeps a run" do
    expect(finishes_after_check("w-fork-unlisted", listing: nil)).to eq(1)
  end

  it "records working, not finished, once the fork writes its own state", :aggregate_failures do
    finishes_after_check("w-fork-own", listing: "busy")
    worked = count("SessionWorking")
    list_and_check("w-fork-own", { state: "working" }, "busy")
    expect(count("SessionWorking")).to eq(worked + 1)
    expect(count("SessionFinished")).to eq(0)
  end
end
