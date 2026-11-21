require "spec_helper"
require "hecks/hecks/adapters/local_overlaying"

# The aggregates one process writes and a later call reads are named by `KeptAggregate` rows, each
# with a reason, so the overlay binds them to the store instead of Memory.
RSpec.describe "cross-call kept rows" do
  rows = nil
  before(:all) do
    registry = boot_hecks_in_memory.registry
    rows = Hecks::Adapters::MainIntegration::KeptRows.from_registry(registry)
  end

  {
    ["Hecks", "Overload"]    => "both",
    %w[Hecks LoadStanding]   => "both",
    ["Hecks", "Roll"]        => "main",
    ["Hecks", "Probe"]       => "main",
    ["Hecks", "RedEpisode"]  => "main",
    ["Agents", "Message"]    => "main",
    ["Agents", "Verdict"]    => "main",
    ["Agents", "Escalation"] => "main",
    ["Agents", "Turn"]       => "main",
    ["Agents", "HandRun"]    => "main"
  }.each do |(domain, aggregate), checkout|
    it "keeps #{domain}::#{aggregate} for the #{checkout} checkout, with a reason", :aggregate_failures do
      row = Hecks::Adapters::MainIntegration::KeptRows.find(rows, domain, aggregate)
      expect(row).not_to be_nil
      expect(row[:checkout]).to eq(checkout)
      expect(row[:reason].to_s.strip).not_to be_empty
    end
  end
end
