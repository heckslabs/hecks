require "spec_helper"
require_relative "support/answer_refused_looks"

# A verdict for a coder run that cannot take it is recorded, not lost to the tap: a run tidied,
# retired or never started records `AnswerRefused` with the reason, and one finished records
# `AgentRunUnreached`, whether the verdict was judged or sent again; either settles the verdict
# undeliverable. A started run is answered and records neither. Scratch state only.
RSpec.describe "a verdict for a coder run that cannot take it" do
  include_context "with a stand-in claude for refused answers"

  before(:all) { @hecks = boot_hecks_in_memory }

  %w[sound changes rethink].each do |word|
    it "records AnswerRefused and settles the verdict undeliverable for a tidied run (#{word})", :aggregate_failures do
      tidied_coder("w-tidied-#{word}")
      judge("j-tidied-#{word}", "w-tidied-#{word}", word)

      expect(recorded("AnswerRefused", "w-tidied-#{word}")).not_to be_empty
      expect(verdicts("undelivered")).to include("j-tidied-#{word}", "the coder run is not started")
    end
  end

  it "records no AnswerRefused for a started run, which is answered" do
    coder_reading("w-started", "blocked")
    judge("j-started", "w-started", "sound")

    expect(recorded("AnswerRefused", "w-started")).to be_empty
  end

  it "records AnswerRefused for a verdict sent again after the run was tidied" do
    redelivered_after_the_end("j-again", "w-again") { tidy("w-again") }

    expect(verdicts("undelivered")).to include("j-again", "the coder run is not started")
  end

  it "records the run unreached for a verdict sent again after the run finished" do
    redelivered_after_the_end("j-finished", "w-finished")

    expect(verdicts("undelivered")).to include("j-finished", "the coder run already finished")
  end
end
