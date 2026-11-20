require "spec_helper"
require_relative "support/refill_queue"

# Keyed by its read, every event that finds the switch on rolls, so a roll that would repeat the
# last report is refused as unchanged and starts nothing.
RSpec.describe "a roll with nothing new to start" do
  include RefillQueue

  before do
    rolling do
      plan_work("alpha")
      plan_work("beta")
      @declined = declined_rolls
      plan_work("gamma")
    end
  end

  it("declines the repeated roll") { expect(declined_rolls - @declined).to eq(1) }

  it("starts nothing more") { expect(board.launches("alpha") + board.launches("beta")).to eq(1) }

  def declined_rolls = hecks.reactions.count { |row| row[:policy] == "RecordTheDeclinedRoll" && row[:delivered] }
end
