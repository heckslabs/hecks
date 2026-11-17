require "spec_helper"
require_relative "support/dispatch_pause_fixtures"

# The owner's pause: while the Tickets world's `dispatch_roll_forward` says `roll_forward: false`,
# or a merge window is open, the roll and the clock's beat start nothing, and a filling held to a
# named work item with `only` still starts it. Every record here is a stand-in; no live store
# is read.
RSpec.describe "the pause on automatic dispatch" do
  include DispatchPauseFixtures

  Failure = Hecks::Adapters::ConsoleCapture::Failure unless defined?(Failure)

  before { Hecks::Adapters::Dispatching::LastRoll.reset! }

  it "starts no roll while the owner has paused" do
    expect { rolling({ roll_forward: false }).roll }.to raise_error(Failure, /paused: dispatch_roll_forward is false/)
  end

  it "starts nothing on the clock's beat while the owner has paused" do
    expect { filling({ roll_forward: false }).notice(run: { value: "beat-1" }) }
      .to raise_error(Failure, /paused: dispatch_roll_forward is false/)
  end

  it "starts no roll while a merge window is open, though the switch is on" do
    window_open(true)

    expect { rolling({ roll_forward: true }).roll }.to raise_error(Failure, /paused/)
  end

  it "rolls when the switch is on and no window is open" do
    window_open(false)

    expect(rolling({ roll_forward: true }).roll[:report][:value]).to include("this fill: 0 started")
  end

  it "reads the pause as off through the Rolling port" do
    expect(rolling({ roll_forward: false }).read[:state]).to eq("off")
  end

  it "refuses a confirmed filling, even one naming a work item, while the owner has stopped new work" do
    expect { named_fill({ roll_forward: false }) }.to raise_error(Failure, /new work is stopped/)
  end

  it "starts the work item a confirmed filling names when the switch is on", :aggregate_failures do
    report = named_fill({ roll_forward: true })

    expect(report).to include("started zz-named")
    expect(report).not_to include("aa-other")
  end

  it "still says what a dry filling would start while new work is stopped" do
    report = filling({ roll_forward: false }).choose(run: { value: "f" }, repo: { value: "/repo" })[:report][:value]

    expect(report).to include("would start")
  end
end
