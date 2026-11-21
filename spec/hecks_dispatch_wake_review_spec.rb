require "spec_helper"
require "hecks/hecks/adapters/dispatching"
require_relative "support/new_work_started"

# What the waker's second review found: a roll skipped by the load is retried when the load falls,
# only a confirmed fill writes what the beat reads, and the beat's own reads stay cheap.
RSpec.describe "the waker after its second review" do
  include_context "with new work started"

  let(:dispatching) { Hecks::Adapters::Dispatching }
  let(:now) { Time.utc(2026, 11, 9, 12, 0, 0) }
  let(:level) { { load: 11.0 } }
  let(:items) { [dispatching::Plan::Item.new(key: "w", title: "w", detail: "", area: ["w"])] }
  let(:work_items) do
    instance_double(dispatching::WorkItems, planned: items, rollable: items, started: [], runs: {}, lessons: [])
  end

  # The committed world pauses rolling while the pipeline's load is reduced; these examples are
  # about what a beat does when rolling is on.
  before do
    dispatching::Pending.reset!
    allow(dispatching::Settings).to(receive(:new).and_wrap_original do |original, *args, **options|
      original.call(*args, **options).tap { |settings| allow(settings).to receive(:roll_forward?).and_return(true) }
    end)
  end

  after { dispatching::Pending.reset! }

  # A heavy minute: 3.6 million boot ms in the last 15 minutes of 12 CPUs is 33 percent of them.
  def boots(heavy)
    row = { "boot_ms" => heavy ? 3_600_000 : 100_000, "at" => (now - 60).iso8601 }
    Hecks::Adapters::BootBudget.new(entries: ->(_cutoff) { [row] }, now: -> { now })
  end

  def adapter(heavy: false)
    settings = { load: -> { level[:load] }, cpus: 12, work_items: work_items, boots: boots(heavy), now: -> { now },
                 runner: ->(*) { raise "no launch" } }
    dispatching.new(registry: boot_hecks_in_memory.registry, settings: settings)
  end

  def confirmed(subject) = subject.choose(repo: { value: "/repo" }, confirm: true)

  # One beat of the clock; nil on a quiet one.
  def beat(subject, number)
    subject.notice(run: { value: "beat-#{number}" })
  rescue Hecks::Adapters::ConsoleCapture::Failure
    nil
  end

  def held_back_by_both
    dispatching::Pending.budget_stopped = true
    dispatching::Pending.load_stopped = true
    level[:load] = 1.0
  end

  describe "a fill held back by the load" do
    it "is remembered by a confirmed fill, and not by a dry preview", :aggregate_failures do
      subject = adapter
      subject.preview(repo: { value: "/repo" })
      expect(dispatching::Pending.load_stopped).to be(false)

      confirmed(subject)
      expect(dispatching::Pending.load_stopped).to be(true)
    end

    it "wakes the beat once the load falls under the limit with no mark crossed", :aggregate_failures do
      subject = adapter
      confirmed(subject)
      expect { subject.notice(run: { value: "beat-1" }) }.to raise_error(/quiet/)

      level[:load] = 3.0
      expect(subject.notice(run: { value: "beat-2" }).dig(:reason, :value)).to include("no longer over its limit")
    end

    it "does not ask the machine unless a fill was held back by it" do
      subject = adapter
      allow(subject).to receive(:machine_clear?).and_return(true)
      beat(subject, 1)

      expect(subject).not_to have_received(:machine_clear?)
    end
  end

  describe "the flags a dry plan leaves alone" do
    it "keeps the budget flag a confirmed stop set when a dry plan reads a freed share", :aggregate_failures do
      confirmed(adapter(heavy: true))
      expect(dispatching::Pending.budget_stopped).to be(true)

      adapter.preview(repo: { value: "/repo" })
      expect(dispatching::Pending.budget_stopped).to be(true)
    end

    it "records when the window alone could free the budget", :aggregate_failures do
      confirmed(adapter(heavy: true))

      expect(dispatching::Pending.budget_frees_at).to eq(now - 60 + (15 * 60))
    end

    it "clears both flags when a confirmed fill is stopped by neither", :aggregate_failures do
      held_back_by_both
      confirmed(adapter)

      expect(dispatching::Pending.budget_stopped).to be(false)
      expect(dispatching::Pending.load_stopped).to be(false)
    end
  end

  describe "the beat's reads" do
    it "reads the planned items once within the cache's time" do
      subject = adapter
      [1, 2].each { |number| beat(subject, number) }

      expect(work_items).to have_received(:rollable).once
    end

    it "reads them again after a confirmed fill changed what is planned" do
      subject = adapter
      beat(subject, 1)
      confirmed(subject)
      beat(subject, 2)

      expect(work_items).to have_received(:rollable).at_least(2).times
    end
  end

  describe "the boot budget on the beat" do
    def wake(frees_at:, stopped: -> { "spent" }, at: now)
      dispatching::Wake.reason([], now: at, stopped: stopped, frees_at: frees_at)
    end

    before { dispatching::Pending.budget_stopped = true }

    it "is not read before the oldest counted boots leave the window", :aggregate_failures do
      dispatching::Pending.budget_frees_at = now + 3600

      expect(wake(frees_at: -> {}, stopped: -> { raise "the usage record was read" })).to be_nil
      expect(dispatching::Pending.budget_frees_at).to eq(now + 3600)
    end

    it "is read again at that time, and says when to look next if still spent", :aggregate_failures do
      dispatching::Pending.budget_frees_at = now - 1

      expect(wake(frees_at: -> { now + 7200 })).to be_nil
      expect(dispatching::Pending.budget_frees_at).to eq(now + 7200)
    end

    it "is read again after ten minutes when the window alone cannot free it" do
      wake(frees_at: -> {})

      expect(dispatching::Pending.budget_frees_at).to eq(now + dispatching::Wake::BUDGET_RECHECK)
    end
  end

  describe Hecks::Adapters::BootBudget do
    def stamped(boot_ms, minutes_ago) = { "boot_ms" => boot_ms, "at" => (now - (minutes_ago * 60)).iso8601 }

    def budget(*rows) = described_class.new(entries: ->(_cutoff) { rows }, now: -> { now })

    def frees_at(*rows, percent: 25.0) = budget(*rows).share_frees_at(percent: percent, minutes: 15, cpus: 12)

    it "names the time the oldest boots leave the share's window far enough to bring it under the mark" do
      expect(frees_at(stamped(2_000_000, 10), stamped(2_000_000, 5))).to eq(now + 300)
    end

    it "names none for a run with no start time, which the window cannot place" do
      expect(frees_at({ "boot_ms" => 9_000_000, "date" => now.strftime("%Y-%m-%d") })).to be_nil
    end

    it "names none when the share is not over the mark" do
      expect(frees_at(stamped(1_000_000, 5))).to be_nil
    end
  end

  describe "the reaction depth of a beat that wakes a fill" do
    def depths = (@depths ||= [])

    def parked
      dispatching::Plan::Item.new(key: "slow", title: "slow", detail: "", area: ["slow"], yield_kind: "transient",
                                  retry_at: (now - 30).iso8601, yield_count: 1)
    end

    # A roll that notes how deep in reactions it was started.
    def roller = Struct.new(:depths) { def roll(**) = (depths << Thread.current[:hecks_reaction_depth].to_i) }.new(depths)

    def waking
      stand_ins = { work_items: instance_double(dispatching::WorkItems, planned: [parked], rollable: [parked]), now: -> { now },
                    load: -> { 0.5 }, cpus: 4 }
      Hecks::Adapters::Waking.new(registry: boot_hecks_in_memory.registry, settings: stand_ins)
    end

    def beat_in(registry)
      lookup = ->(port, _asked) { port.to_s == "Waking" ? waking : roller }
      Hecks::Runtime::AdapterLookup.standing_in(lookup) do
        Hecks::Runtime::Dispatcher.new(registry).dispatch_flat("Hecks::Heartbeat.Beat", beat: { value: "beat-1" })
      end
    end

    # Beats once through the real Heartbeat chain, the real waker and a roll that notes its depth.
    def names_of_the_beat
      registry = boot_hecks_in_memory(File.expand_path("../lib/hecks/hecks", __dir__)).registry
      beat_in(registry)
      registry.event_log.map(&:name)
    end

    it "reaches the fill with depth to spare, so a session start is not refused", :aggregate_failures do
      expect(names_of_the_beat).to include("WakeDue", "RollRequested")
      expect(depths.first).to be < Hecks::Runtime::Dispatcher::MAX_REACTION_DEPTH
    end
  end

  describe "the clock's filling count" do
    it "is the process's, so another thread sees a filling that a command line started", :aggregate_failures do
      seen = nil
      dispatching::Filling.during(true) { seen = Thread.new { dispatching::Filling.running? }.value }

      expect(seen).to be(true)
      expect(dispatching::Filling.running?).to be(false)
    end

    it "is released when the filling raises", :aggregate_failures do
      expect { dispatching::Filling.during(true) { raise "boom" } }.to raise_error("boom")
      expect(dispatching::Filling.running?).to be(false)
    end
  end
end
