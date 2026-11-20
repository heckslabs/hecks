require "spec_helper"
require "hecks/hecks/adapters/dispatching"

# A planned work item names what it waits on (its `waits_on`, or a line of its detail) and
# waits until that work item is met: done, or named by a landed branch.
RSpec.describe Hecks::Adapters::Dispatching::Dependencies do
  let(:statuses) { { "dep" => "done", "late" => "done", "open" => "started", "gone" => "dropped" } }

  def item(detail, waits_on: nil)
    Hecks::Adapters::Dispatching::Plan::Item.new(key: "w", title: "w", detail: detail, area: [], waits_on: waits_on)
  end

  def facts
    reads = Struct.new(:statuses) do
      def landed_commits(key) = key == "dep" ? %w[1111] : []
      def status_of(key) = statuses[key]
    end
    reads.new(statuses)
  end

  def reason(detail) = described_class.new(facts).reason(item(detail))

  it "reads the keys a detail names on a line of its own, never its own key or a sentence", :aggregate_failures do
    expect(described_class.of(item("Build it.\nDepends on: a, qa-b, w.\nThen report."))).to eq(%w[a qa-b])
    expect(described_class.of(item("This depends on a, which is not built."))).to eq([])
  end

  it "waits on a work item that is started and has not landed", :aggregate_failures do
    expect(reason("Depends on: open")).to eq("skipped: waits on open")
    expect(reason("depends on: dep, late, open")).to eq("skipped: waits on open")
  end

  it "lets an item start once a landed branch names its dependency" do
    expect(reason("Depends on: dep")).to be_nil
  end

  it "lets an item waiting on a done work item start, though no landing names it" do
    expect(reason("Depends on: late")).to be_nil
  end

  it "lets an item start on a landed dependency whose status is not yet done" do
    statuses["dep"] = "started"
    expect(reason("Depends on: dep")).to be_nil
  end

  it "says when no landing can end the wait", :aggregate_failures do
    expect(reason("Depends on: nobody")).to eq("skipped: waits on nobody (no such work item)")
    expect(reason("Depends on: gone")).to eq("skipped: waits on gone (dropped)")
  end

  it "reads the keys the item waits on first, then its detail's, never its own" do
    expect(described_class.of(item("Depends on: a, b", waits_on: %w[b open w]))).to eq(%w[b open a])
  end

  it "waits on a declared work item that has not landed" do
    expect(described_class.new(facts).reason(item("", waits_on: %w[dep open]))).to eq("skipped: waits on open")
  end
end
