# frozen_string_literal: true

require "spec_helper"
require "json"
require "tmpdir"
require "hecks/tickets/bluebook/adapters/velocity"

# Work.velocity reports the hours of work finished on a day: a work item that recorded the
# pomodoros it spent counts them at 25 minutes each, and one that recorded none is read from git
# history as an inferred span from its branch's first commit to its merge.
RSpec.describe Hecks::Adapters::Velocity do
  let(:tap) { File.join(Dir.mktmpdir("velocity"), "events.jsonl") }
  let(:spans) { { "inferred-one" => 3 * 3600, "no-commits" => nil } }
  let(:entries) do
    [{ work: "recorded-one", title: "Recorded", pomodoros_spent: 6 },
     { work: "inferred-one", title: "Inferred", pomodoros_spent: 0 },
     { work: "no-commits", title: "Unread" }, { work: "other-day", title: "Yesterday", pomodoros_spent: 4 }]
  end

  def finish(key, day)
    JSON.generate(kind: "event", at: "#{day}T10:00:00Z", aggregate: "Tickets::Work", id: key, event: "WorkFinished", seq: 1)
  end

  def registry
    bluebook = double(aggregates: [double(hecks_name: "Work")])
    double(bluebook: bluebook, repository: double(all: entries))
  end

  def lines(day)
    [finish("recorded-one", day), finish("inferred-one", day), finish("no-commits", day),
     finish("other-day", "2026-11-22")]
  end

  def text(day = "2026-11-23")
    File.write(tap, lines(day).join("\n"))
    stand_ins = { tap: tap, span: ->(key) { spans[key] } }
    described_class.new(registry: registry, settings: stand_ins).velocity(day: { value: day })[:text]
  end

  it "reports a recorded item as its pomodoros times 25 minutes in hours" do
    expect(text).to include("recorded-one: Recorded - 2.5 h (6 pomodoros)")
  end

  it "marks an item with no recorded spend INFERRED from its commits" do
    expect(text).to include("inferred-one: Inferred - 3.0 h INFERRED")
  end

  it "marks an item git cannot span INFERRED with unknown hours, not zero" do
    expect(text).to include("no-commits: Unread - unknown INFERRED")
  end

  it "splits the day into recorded and INFERRED totals" do
    expect(text.lines.map(&:strip)).to include("Recorded: 2.5 h", "INFERRED: 3.0 h", "Total: 5.5 h")
  end

  it "leaves out an item that finished on another day" do
    expect(text).not_to include("other-day")
  end
end
