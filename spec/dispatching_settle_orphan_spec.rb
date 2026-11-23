require "spec_helper"
require "hecks/hecks/adapters/dispatching"

# A started work item whose runs are gone and whose landing is not under way holds a place for
# nothing: the settle sends it back to the plan. One the dispatch only just started, one a person
# claimed, one with a live run and one whose landing is in flight keep their place.
RSpec.describe "the settle of a started work item with no live run" do
  let(:now) { Time.utc(2026, 11, 17, 12, 0, 0) }
  let(:item) { Hecks::Adapters::Dispatching::Plan::Item.new(key: "w", title: "w", detail: "", area: []) }
  let(:launcher) { instance_double(Hecks::Adapters::Dispatching::Launcher, check_all: nil, yield_back: "yielded w") }
  let(:live) { { "w" => { status: "started", condition: "", session: "s", started_at: now.iso8601 } } }

  # The facts the settle reads, each overridable.
  def facts(**given)
    { started: [item], runs: {}, claimant: "dispatch", claimed_at: "2026-11-17T10:00:00Z",
      landing_in_flight?: false }.merge(given)
  end

  def settle(**given)
    work = instance_double(Hecks::Adapters::Dispatching::WorkItems, **facts(**given))
    orphans = Hecks::Adapters::Dispatching::OrphanedWork.new(work, min_age: 600, clock: -> { now })
    Hecks::Adapters::Dispatching::Settler.new(work, launcher, clock: -> { now }, orphans: orphans).call
  end

  it "yields the orphan back to the plan, naming why", :aggregate_failures do
    expect(settle).to eq(["yielded w"])
    expect(launcher).to have_received(:yield_back).with(item, /no live run and no landing in flight/)
  end

  {
    "whose run is live"                 => -> { { runs: live } },
    "whose landing is in flight"        => -> { { landing_in_flight?: true } },
    "a person claimed"                  => -> { { claimant: "chris" } },
    "the dispatch started a moment ago" => -> { { claimed_at: (now - 30).iso8601 } }
  }.each do |name, given|
    it("leaves an item #{name}, saying so") { expect(settle(**instance_exec(&given))).to match([/\Aleft w: /]) }
  end

  it "yields an item whose only run row is from an earlier start, older than its claim" do
    old = { "w" => { status: "started", started_at: "2026-11-17T08:00:00Z", session: "s" } }
    expect(settle(runs: old)).to eq(["yielded w"])
  end

  it "leaves an item whose run began after its claim" do
    fresh = { "w" => { status: "started", started_at: "2026-11-17T10:01:00Z", session: "s" } }
    expect(settle(runs: fresh)).to match([/\Aleft w: /])
  end

  it "counts a run row with no readable start as an earlier start" do
    blank = { "w" => { status: "started", started_at: "", session: "s" } }
    expect(settle(runs: blank)).to eq(["yielded w"])
  end

  it "reads the start window from the world, in seconds" do
    verbs = Struct.new(:rows) { def for_verb(_verb) = rows }.new({ minutes: 3 })
    registry = Struct.new(:verbs) { def world(_name) = verbs }.new(verbs)
    expect(Hecks::Adapters::Dispatching::Settings.new(registry).start_window_seconds).to eq(180)
  end
end
