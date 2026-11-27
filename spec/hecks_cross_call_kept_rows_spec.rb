require "spec_helper"
require "hecks/hecks/adapters/local_overlaying"

# The aggregates one process writes and a later call reads are named by `KeptAggregate` rows, each
# with a reason, so the overlay binds them to the store instead of Memory.
RSpec.describe "cross-call kept rows" do
  rows = nil
  before(:all) do
    registry = boot_hecks_in_memory.registry
    rows = Hecks::Adapters::KeptRows.from_registry(registry)
  end

  {
    %w[Hecks Operation]       => "both",
    %w[Hecks ModelCheckRun]   => "both",
    %w[Tickets Finding]       => "main",
    %w[Tickets Work]          => "main",
    %w[Tickets Sprint]        => "main",
    %w[Protocols Agreement]   => "main"
  }.each do |(domain, aggregate), checkout|
    it "keeps #{domain}::#{aggregate} for the #{checkout} checkout, with a reason", :aggregate_failures do
      row = Hecks::Adapters::KeptRows.find(rows, domain, aggregate)
      expect(row).not_to be_nil
      expect(row[:checkout]).to eq(checkout)
      expect(row[:reason].to_s.strip).not_to be_empty
    end
  end
end
