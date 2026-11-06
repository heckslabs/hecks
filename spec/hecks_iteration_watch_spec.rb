require "spec_helper"
require "hecks/hecks/adapters/iteration_watch"

# The three rules that make a started Work row bloated, over a stand-in event log and a fixed clock.
RSpec.describe Hecks::Adapters::IterationWatch do
  let(:claimed) { Time.utc(2026, 11, 1, 9, 0, 0) }
  let(:rows) { [{ key: "qa/x", claimed_by: "s", claimed_at: claimed, budget_minutes: 0 }] }
  let(:event) { Hecks::Adapters::IterationWatch::Log::Event }
  let(:events) { [] }

  def event_at(minute, name, **payload)
    wrapped = payload.transform_keys(&:to_s).transform_values { |v| v.is_a?(Integer) ? v : { "value" => v } }
    event.new(name, "run-#{minute}", wrapped, claimed + (minute * 60), "qa/x #{payload.values.join(" ")}")
  end

  def refused(minute, reason, name: "MintRefused") = event_at(minute, name, refusal: reason)

  def breaches(minutes_after: 10)
    allow(Hecks::Adapters::StartedWork).to receive(:claimed).and_return(rows)
    log = instance_double(Hecks::Adapters::IterationWatch::Log, events: events)
    described_class.new(nil, log: log, now: claimed.to_i + (minutes_after * 60)).breaches
  end

  def lines(**) = breaches(**).map(&:line)

  describe "attempts" do
    it "trips on 3 refusals of one kind in a row and names the reason", :aggregate_failures do
      events.push(refused(1, "stale watermark 7"), refused(2, "stale watermark 8"), refused(3, "stale watermark 9"))

      expect(lines).to eq(["qa/x [attempts]: 3 refused mints in a row, same reason: stale watermark N"])
    end

    it "does not trip on 2" do
      events.push(refused(1, "stale watermark"), refused(2, "stale watermark"))

      expect(lines).to eq([])
    end

    it "starts again when the reason changes" do
      events.push(refused(1, "stale watermark"), refused(2, "stale watermark"), refused(3, "rehearsal is red"))

      expect(lines).to eq([])
    end

    it "starts again after the step went through" do
      events.push(refused(1, "q"), refused(2, "q"), event_at(3, "BranchLanded"), refused(4, "q"))

      expect(lines).to eq([])
    end

    it "ignores failures before the claim and those of other rows" do
      events.push(refused(-5, "q"), refused(-4, "q"), refused(-3, "q"))
      events.push(event.new("MintRefused", "r", { "refusal" => "q" }, claimed + 60, "qa/other"))

      expect(lines).to eq([])
    end
  end

  describe "waiting" do
    it "sums recorded and worded waits and names the numbers" do
      events.push(event_at(1, "BranchLanded", waited_seconds: 600), event_at(2, "LandingRefused", refusal: "queue busy: waited 17m 0s behind a"))

      expect(lines).to eq(["qa/x [waiting]: waited 27 min of 15"])
    end

    it "does not trip on a short wait" do
      events.push(event_at(1, "BranchLanded", waited_seconds: 600))

      expect(lines).to eq([])
    end
  end

  describe "budget" do
    it "trips past the multiple of the row's budget" do
      rows.first[:budget_minutes] = 30

      expect(lines(minutes_after: 46)).to eq(["qa/x [budget]: 46 of 30 min"])
    end

    it "is quiet within the multiple" do
      rows.first[:budget_minutes] = 30

      expect(lines(minutes_after: 44)).to eq([])
    end

    it "uses the default budget for a row with none" do
      expect(lines(minutes_after: 71)).to eq(["qa/x [budget]: 71 of 45 min"])
    end

    it "does not time a row with no claim time" do
      rows.first[:claimed_at] = nil

      expect(lines(minutes_after: 100_000)).to eq([])
    end
  end

  it "reads the limits from the Tickets world" do
    world = instance_double(Hecks::Bluebook::World, for_verb: { attempts: 5, wait_minutes: 20, over_budget: 2.0, default_budget_minutes: 60 })
    registry = instance_double(Hecks::Runtime::Registry, world: world)

    expect(Hecks::Adapters::IterationWatch::Setting.read(registry).to_a).to eq([5, 20, 2, 60])
  end
end
