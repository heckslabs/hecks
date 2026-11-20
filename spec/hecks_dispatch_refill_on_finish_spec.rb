require "spec_helper"
require_relative "support/refill_queue"

# A work item a roll skips because another holds its area starts when the holder ends: the
# landing's close (`WorkFinished`) rolls the queue, so no one calls `Dispatch.fill!` again.
RSpec.describe "the roll a holder's landing starts" do
  include RefillQueue

  before do
    rolling do
      plan_work("alpha")
      plan_work("beta")
      @waited = board.launches("beta")
      land("alpha")
    end
  end

  it "leaves the overlapping item waiting while the holder is started" do
    expect(@waited).to eq(0)
  end

  it "starts the waiting item once the holder's close is recorded" do
    expect(board.launches("beta")).to eq(1)
  end

  it "delivers the roll on WorkFinished" do
    expect(reaction("RollWhenWorkIsFinished")).to include(trigger: "Hecks::RollSwitch.Consult", delivered: true)
  end
end
