require "spec_helper"
require "json"
require_relative "support/registry_double"
require "hecks/tickets/bluebook/adapters/work_show"

# The WorkShow port's adapter against a stubbed Work repository: one work item as JSON, with the
# started work items whose claimed area meets its own.
RSpec.describe Hecks::Adapters::WorkShow do
  include RegistryDouble

  Word = Struct.new(:value)

  def item(key, status, area, claimed_by = "")
    { work: key, title: "t #{key}", status: status, area: area.map { |path| Word.new(path) }, claimed_by: claimed_by }
  end

  def show(items, key)
    registry = registry_double
    allow(registry).to receive(:repository).and_return(Struct.new(:all).new(items))
    allow(Hecks::Adapters::StartedWork).to receive(:work_aggregate).and_return(Object.new)
    described_class.new(registry: registry).show(work: key)
  end

  def shown(items, key) = JSON.parse(show(items, key)[:text])

  let(:items) do
    [item("a", "started", ["lib/hecks/tickets"], "coder-1"), item("b", "started", ["lib/hecks"]),
     item("c", "started", ["docs"]), item("d", "planned", ["lib/hecks/tickets"])]
  end

  it "answers the status, claimant and area", :aggregate_failures do
    found = shown(items, "a")

    expect(found.values_at("status", "claimed_by", "area")).to eq(["started", "coder-1", ["lib/hecks/tickets"]])
  end

  it "names the started work items whose area overlaps, never itself" do
    expect(shown(items, "d")["overlap"].map { |row| row["with"] }).to eq(%w[a b])
  end

  it "gives the paths that met", :aggregate_failures do
    row = shown(items, "d")["overlap"].last

    expect(row.values_at("mine", "theirs")).to eq(["lib/hecks/tickets", "lib/hecks"])
  end

  it "reports no overlap for a work item with no area" do
    expect(shown([item("e", "planned", [])] + items.first(1), "e")["overlap"]).to eq([])
  end

  it "refuses a key no work item has" do
    expect { show(items, "nope") }.to raise_error(Hecks::Adapters::ConsoleCapture::Failure, "no work item nope")
  end

  it "accepts the key wrapped as a value" do
    expect(show(items, "c")[:text]).to include('"work": "c"')
  end
end
