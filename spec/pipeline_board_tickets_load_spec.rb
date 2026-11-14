# frozen_string_literal: true

require "spec_helper"
require "json"
require "hecks/pipeline_board/adapters/pipeline_tickets"

# The board's Tickets reader with no live store: the readers of one refresh (the open work, its
# counts, the epics) share one load of each aggregate from the board's own registry.
RSpec.describe Hecks::Adapters::PipelineTickets do
  let(:loads) { Hash.new(0) }
  let(:tickets) { described_class.new(registry: registry, settings: { live_store: nil }) }

  def work = { work: "board-bounded-reads", status: "planned", title: "Bounded reads", epic: "board" }

  def records = { "Work" => [work], "Epic" => [{ epic: "board", title: "Board" }] }

  # A registry of the Tickets aggregates above that counts each load of one.
  def registry
    names = records.keys.map { |name| Struct.new(:hecks_name).new(name) }
    double(bluebook: Struct.new(:aggregates).new(names)).tap do |found|
      allow(found).to receive(:repository) { |_domain, aggregate| repository(aggregate.hecks_name) }
    end
  end

  def repository(name)
    double.tap { |held| allow(held).to receive(:all) { (loads[name] += 1) && records.fetch(name) } }
  end

  it "loads the Work items once for the open work, the counts and the epics", :aggregate_failures do
    open = JSON.parse(tickets.open_work[:text]).map { |item| item["slug"] }
    expect([open, tickets.counts, tickets.epics.size]).to eq([["board-bounded-reads"], { "planned" => 1 }, 1])
    expect(loads).to eq("Work" => 1, "Epic" => 1)
  end

  it "says the registry declares no such aggregate when the domain is not booted here" do
    bare = described_class.new(settings: { live_store: nil })
    expect { bare.counts }.to raise_error(Hecks::Adapters::PipelineBoard::Unavailable, /declares no Tickets.Work/)
  end
end
