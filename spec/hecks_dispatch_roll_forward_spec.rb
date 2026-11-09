require "spec_helper"
require_relative "support/roll_forward_fixtures"

# A rolling fill runs when a policy reacts; the owner's switch pauses it and a repeated report is
# recorded once.
RSpec.describe "a rolling fill" do
  include RollForwardFixtures

  Failure = Hecks::Adapters::ConsoleCapture::Failure

  before { Hecks::Adapters::Dispatching::LastRoll.reset! }

  it "is answered through the Rolling port when a roll is started", :aggregate_failures do
    expect(start_roll).to include("RollRequested", "RollReported", "RollAnswered")
  end

  it "starts nothing while the owner has paused rolling" do
    expect { rolling({ roll_forward: false }).roll }.to raise_error(Failure, /paused/)
  end

  it "records a repeated report once", :aggregate_failures do
    roller = rolling({})

    expect(roller.roll[:report][:value]).to include("this fill: 0 started, 0 yielded of 0")
    expect { roller.roll }.to raise_error(Failure, /unchanged/)
  end

  # The session that landed the branch ends, and that end rolls; a roll at the landing itself would
  # count the holder as still started and start nothing.
  it "is not started by a landed branch" do
    bluebook = Hecks.describe(File.expand_path("../lib/hecks/hecks", __dir__)).registry.bluebooks.fetch("Hecks")
    rolls = bluebook.policies.select { |policy| policy.name.start_with?("Roll") }

    expect(rolls.map(&:on_event)).not_to include("Landing.BranchLanded")
  end
end
