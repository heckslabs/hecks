require "spec_helper"
require "hecks/hecks/adapters/dispatching"
require_relative "support/stall_watch_looks"

# A work item is a stall item when its key starts with a declared `StallKind` row's prefix.
RSpec.describe Hecks::Adapters::Dispatching::WorkItems do
  include_context "with a stall watch tap"

  it "names a stall item by a declared kind's prefix only", :aggregate_failures do
    items = described_class.new(registry)

    expect(items.stall_item?("stall-landing-carry-57964c20")).to be(true)
    expect(items.stall_item?("stall-train-events")).to be(false)
  end
end
