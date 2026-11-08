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

    expect(roller.roll[:report][:value]).to include("0 to start")
    expect { roller.roll }.to raise_error(Failure, /unchanged/)
  end
end
