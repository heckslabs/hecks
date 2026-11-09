require "spec_helper"
require_relative "support/roll_forward_fixtures"
require "hecks/hecks/adapters/waking"

# Almost everything that rolls the queue is an event. What becomes eligible by the clock alone
# (a retry time passing, a spent boot budget freeing, a roll refused while a filling ran) is asked
# on each beat, and a roll follows only when something did.
RSpec.describe "waking the queue on the clock" do
  include RollForwardFixtures

  let(:dispatching) { Hecks::Adapters::Dispatching }
  let(:now) { Time.utc(2026, 11, 9, 12, 0, 0) }

  before { dispatching::Pending.reset! }

  after { dispatching::Pending.reset! }

  def parked(key, retry_at, kind: "transient")
    RollForwardFixtures::Item.new(key: key, title: key, detail: "", area: [], yield_kind: kind,
                                  retry_at: retry_at.iso8601, yield_count: 1)
  end

  def reason(items, stopped: -> {}, at: now) = dispatching::Wake.reason(items, now: at, stopped: stopped)

  it "stays quiet when nothing is parked, due, deferred or freed" do
    expect(reason([])).to be_nil
  end

  it "wakes once when a retry time passes between two looks", :aggregate_failures do
    item = parked("slow", now - 30)
    reason([item], at: now - 120)

    expect(reason([item])).to eq("the retry time of slow has passed")
    expect(reason([item], at: now + 60)).to be_nil
  end

  it "does not wake for a retry time still in the future" do
    expect(reason([parked("later", now + 600)])).to be_nil
  end

  it "wakes for a missing Passage's hour passing" do
    expect(reason([parked("pass", now - 5, kind: "missing_passage")])).to include("pass")
  end

  it "wakes for a retry time that passed before the first look of a new process" do
    expect(reason([parked("old", now - 86_400)])).to include("old")
  end

  it "wakes once when the boot budget that stopped the plan is no longer spent", :aggregate_failures do
    dispatching::Pending.budget_stopped = true

    expect(reason([], stopped: -> { "skipped: boot budget spent" })).to be_nil
    expect(reason([], stopped: -> {}, at: now + 700)).to eq("the boot budget is no longer spent")
    expect(reason([], stopped: -> {}, at: now + 800)).to be_nil
  end

  it "does not read the budget unless the last plan was stopped by it" do
    expect(reason([], stopped: -> { raise "the usage record was read" })).to be_nil
  end

  it "wakes once for a roll that was refused while a filling ran", :aggregate_failures do
    dispatching::Pending.defer!

    expect(reason([])).to eq("a roll was refused while a filling ran")
    expect(reason([])).to be_nil
  end

  describe "the adapter's answer" do
    let(:items) { instance_double(dispatching::WorkItems, planned: [parked("due", now - 5)]) }
    let(:adapter) do
      dispatching.new(registry: registry_of([]), settings: { work_items: items, now: -> { now }, load: -> { 0.5 }, cpus: 4 })
    end

    it "answers the key of the roll to start and why", :aggregate_failures do
      answer = adapter.notice(run: { value: "beat-9" })

      expect(answer.dig(:roll, :value)).to eq("due-beat-9")
      expect(answer.dig(:reason, :value)).to include("due")
    end

    it "refuses a quiet beat by name" do
      adapter.notice(run: { value: "beat-1" })

      expect { adapter.notice(run: { value: "beat-2" }) }.to raise_error(Hecks::Adapters::ConsoleCapture::Failure, /quiet/)
    end

    it "does not consume a wake while rolling is paused", :aggregate_failures do
      paused = dispatching.new(registry: registry_of([], { roll_forward: false }),
                               settings: { work_items: items, now: -> { now } })

      expect { paused.notice(run: { value: "beat-1" }) }.to raise_error(/paused/)
      expect(dispatching::Pending.looked_at).to be_nil
    end
  end

  describe "through the clock's beat" do
    def beat_names(answer)
      registry = boot_hecks_in_memory(File.expand_path("../lib/hecks/hecks", __dir__)).registry
      waking = Struct.new(:answer) { def notice(**) = answer.call }.new(answer)
      lookup = ->(port, _asked) { port.to_s == "Waking" ? waking : rolling({}) }
      Hecks::Runtime::AdapterLookup.standing_in(lookup) do
        Hecks::Runtime::Dispatcher.new(registry).dispatch_flat("Hecks::Heartbeat.Beat", beat: { value: "beat-1" })
      end
      registry.event_log.map(&:name)
    end

    it "starts no roll on a quiet beat", :aggregate_failures do
      names = beat_names(-> { raise Hecks::Adapters::ConsoleCapture::Failure, "quiet: nothing" })

      expect(names).to include("WakeRequested", "WakeQuiet")
      expect(names).not_to include("RollRequested")
    end

    it "starts a roll when something is due", :aggregate_failures do
      names = beat_names(-> { { roll: { value: "due-beat-1" }, reason: { value: "a retry time passed" } } })

      expect(names).to include("WakeDue", "RollRequested")
      expect(names).to include("WakeHeard")
    end
  end
end
