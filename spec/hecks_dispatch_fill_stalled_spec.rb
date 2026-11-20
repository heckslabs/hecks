require "spec_helper"
require_relative "support/fill_stall_watches"
require_relative "support/refill_queue"

# A fill that starts nothing for fifteen minutes while work waits and places are free records
# FillStalled once, with its reason, and the first start after it records FillStallCleared. The
# booted Hecks domain runs in Memory; the queue, the machine and the clock are stand-ins.
RSpec.describe "a stalled fill raises its reason", :aggregate_failures do
  include FillStallWatches

  let(:hecks) { boot_hecks_in_memory }
  let(:sessions) { RefillQueue::Answering.new }

  after { FillStallWatches::DISPATCHING::Pending.reset! }

  def names = hecks.registry.event_log.map(&:name)

  def ports(&)
    wiring = ->(port, _asked) { port.to_s == "Dispatching" ? stall_dispatching(hecks.registry) : sessions }
    Hecks::Runtime::AdapterLookup.standing_in(wiring, &)
  end

  def send_stall(command, **arguments) = ports { hecks.dispatch_flat("Hecks::FillStall.#{command}", **arguments) }

  def watch(beat) = send_stall("Watch", fill_stall: "fill", run: { value: beat })

  # Opens the record and marks its last start; each later watch is a beat of the clock.
  def last_start(minutes_ago)
    send_stall("Open", stall: { value: "fill" })
    send_stall("Mark", fill_stall: "fill", since: { value: minutes_before(minutes_ago) })
  end

  def start_work(key, at:)
    ports do
      hecks.dispatch_flat("Tickets::Work.Plan", work: { value: key }, title: { value: key }, detail: { value: "d" }, area: [])
      hecks.dispatch_flat("Tickets::Work.Start", work: { value: key }, claimed_by: { value: "spec" }, claimed_at: { value: at })
    end
  end

  def said(*fields) = fields.map { |field| stall[field][:value] }

  def mark_start_now = send_stall("Mark", fill_stall: "fill", since: { value: minutes_before(0) })

  def stall
    registry = hecks.registry
    registry.repository("Hecks", registry.bluebook("Hecks").aggregate("FillStall")).find("fill")
  end

  it "raises FillStalled once for a held fill with room, however many beats watch it" do
    last_start(16)
    %w[beat-1 beat-2 beat-3].each { |beat| watch(beat) }

    expect(names.count("FillStalled")).to eq(1)
    expect(names).not_to include("FillStallCleared")
  end

  it "records the reason, the reading, how long it has held and what governs it" do
    last_start(40)
    watch("beat-1")

    expect(said(:reason, :held_minutes)).to eq(["1 held by load", 40])
    expect(said(:reading, :governed_by)).to eq(["load 22.8 from uptime against dispatch_max_load 10.0",
                                                "dispatch_max_load in the Tickets world"])
  end

  it "clears the stall when a start happens" do
    last_start(16)
    watch("beat-1")
    mark_start_now && watch("beat-2")

    expect(names.count("FillStallCleared")).to eq(1)
    expect(stall[:standing][:value]).to eq(0)
  end

  it "marks the start and watches again when a Work item starts" do
    start_work("item-1", at: "2026-11-20T09:59:00Z")

    expect(names).to include("WorkStarted", "FillStartMarked", "FillGauged")
    expect(stall[:since][:value]).to eq("2026-11-20T09:59:00Z")
  end

  it "raises nothing before fifteen minutes have passed" do
    last_start(14)
    watch("beat-1")

    expect(names).not_to include("FillStalled")
  end

  it "raises nothing when the cap is full or nothing waits" do
    last_start(16)
    [{ started: 7 }, { started: 5, planned: 0 }].each { |change| stall_machine.merge!(change) && watch("beat") }

    expect(names).not_to include("FillStalled")
  end

  it "counts a store that recorded no start from its first watch" do
    send_stall("Open", stall: { value: "fill" })
    watch("beat-1")

    expect(stall[:since][:value]).to eq("2026-11-20T10:00:00Z")
    expect(names).not_to include("FillStalled")
  end
end
