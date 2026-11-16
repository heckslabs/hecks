require "spec_helper"
require "hecks/hecks/adapters/waking"

# A free slot that no event announced (the cap was raised, a roll was cut short, the event passed
# while the plan was paused) is found by the next beat, which rolls the queue only when the
# filling's own plan would start something.
RSpec.describe "a beat that fills a free slot no event announced" do
  let(:dispatching) { Hecks::Adapters::Dispatching }
  let(:now) { Time.utc(2026, 11, 15, 8, 30, 0) }
  let(:machine) { { load: 2.1, cap: 3, rolling: true } }

  before do
    dispatching::Pending.reset!
    allow(dispatching::Settings).to(receive(:new).and_wrap_original do |original, *args, **options|
      original.call(*args, **options).tap { |settings| allow(settings).to receive(:roll_forward?) { machine[:rolling] } }
    end)
  end

  after { dispatching::Pending.reset! }

  def item(key) = dispatching::Plan::Item.new(key: key, title: key, detail: "", area: [key])

  def work_items
    planned = [item("planned-one")]
    instance_double(dispatching::WorkItems, planned: planned, rollable: planned, started: [item("live-a"), item("live-b")],
                                            runs: {}, lessons: [])
  end

  def budget = Hecks::Adapters::BootBudget.new(entries: ->(_cutoff) { [] }, now: -> { now })

  def waking
    settings = { load: -> { machine[:load] }, cpus: 10, cap: machine[:cap], work_items: work_items, boots: budget,
                 now: -> { now }, runner: ->(*) { raise "no launch" } }
    Hecks::Adapters::Waking.new(registry: boot_hecks_in_memory.registry, settings: settings)
  end

  # One beat's answer: why it rolls, or the refusal's message.
  def beat
    waking.notice(run: { value: "beat-1" }).dig(:reason, :value)
  rescue Hecks::Adapters::ConsoleCapture::Failure => e
    e.message
  end

  it "wakes for a free slot under the cap with work planned and calm load" do
    expect(beat).to eq("a slot is free and a filling would start 1")
  end

  it "stays quiet when the cap is full" do
    machine[:cap] = 2
    expect(beat).to start_with("quiet")
  end

  it "stays quiet while the load is over its limit" do
    machine[:load] = 12.0
    expect(beat).to start_with("quiet")
  end

  it "stays quiet while the owner's switch pauses rolling" do
    machine[:rolling] = false
    expect(beat).to start_with("paused")
  end

  it "stays quiet while a filling runs, so no second filling starts" do
    expect(dispatching::Filling.during(true) { beat }).to start_with("quiet")
  end

  describe "through the clock's beat" do
    # A roll that records its key.
    def roller(rolls) = Struct.new(:rolls) { def roll(**held) = (rolls << held[:run]) && { report: { value: "ok" } } }.new(rolls)

    # Beats once through the real Heartbeat chain and the real waker.
    def names_of_the_beat(rolls)
      registry = boot_hecks_in_memory(File.expand_path("../lib/hecks/hecks", __dir__)).registry
      lookup = ->(port, _asked) { port.to_s == "Waking" ? waking : roller(rolls) }
      Hecks::Runtime::AdapterLookup.standing_in(lookup) do
        Hecks::Runtime::Dispatcher.new(registry).dispatch_flat("Hecks::Heartbeat.Beat", beat: { value: "beat-1" })
      end
      registry.event_log.map(&:name)
    end

    it "starts one roll when a slot is free", :aggregate_failures do
      rolls = []
      expect(names_of_the_beat(rolls)).to include("WakeDue", "RollRequested")
      expect(rolls.size).to eq(1)
    end

    it "starts no roll while a filling runs", :aggregate_failures do
      rolls = []
      names = dispatching::Filling.during(true) { names_of_the_beat(rolls) }

      expect(names).not_to include("RollRequested")
      expect(rolls).to be_empty
    end
  end
end
