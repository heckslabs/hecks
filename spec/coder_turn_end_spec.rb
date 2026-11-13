require "spec_helper"

# A coder's turn ends done only after its branch landed or was submitted: `Turn.End` refuses by
# name a turn that holds its Work item, asks nothing, and has neither landed nor submitted. Each
# fact that lets a turn end is shown alone.
RSpec.describe "a coder's turn ending" do
  before(:all) { @hecks = boot_hecks_in_memory }

  def launch(*argv) = Hecks::Adapters::Driving::CliRunner.call(runtime: @hecks, argv: argv, program: "hecks")

  def end_turn(work, asking: false, landed: false, submitted: false, held: true)
    launch("coder", "Turn.end!", "work.value=#{work}", "asking.value=#{asking}", "landed.value=#{landed}",
           "submitted.value=#{submitted}", "held.value=#{held}", "--wait").join("\n")
  end

  it "refuses a turn that ends done with nothing landed or submitted" do
    expect(end_turn("t-bare")).to include("a coder ends done only after landing or submitting its branch")
  end

  it "tells the refused coder to submit" do
    expect(end_turn("t-told")).to include("coder Submission.submit!")
  end

  it "ends a turn whose last words ask a question" do
    expect(end_turn("t-asks", asking: true)).to include("TurnEnded")
  end

  it "ends a turn whose branch landed" do
    expect(end_turn("t-landed", landed: true)).to include("TurnEnded")
  end

  it "ends a turn whose branch was submitted" do
    expect(end_turn("t-submitted", submitted: true)).to include("TurnEnded")
  end

  it "ends a turn whose Work item the coder no longer holds" do
    expect(end_turn("t-yielded", held: false)).to include("TurnEnded")
  end
end
