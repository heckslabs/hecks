require "spec_helper"
require_relative "support/refill_queue"

# A holder that yields frees its area too, and its yield rolls the queue. A yield made inside a
# running fill asks for a roll the fill defers: it fills once more, and the yielded item, parked
# by its backoff, is not launched again.
RSpec.describe "the roll a work item's yield starts" do
  include RefillQueue

  context "when the holder yields" do
    before do
      rolling do
        plan_work("alpha")
        plan_work("beta")
        yield_holder("alpha")
      end
    end

    it("delivers the roll on WorkYielded") { expect(reaction("RollWhenWorkIsYielded")).to include(delivered: true) }

    it("starts the waiting item") { expect(board.launches("beta")).to eq(1) }
  end

  context "when a launch fails inside a fill" do
    before do
      failing << "alpha"
      rolling { plan_work("alpha") }
    end

    it("launches the failing item once: its yield is parked") { expect(board.launches("alpha")).to eq(1) }

    it("fills once more for the deferred roll and no more") { expect(board.fills).to eq(2) }
  end
end
