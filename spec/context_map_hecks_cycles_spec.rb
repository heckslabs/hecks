require "spec_helper"
require "hecks/bluebook/model_check"

# The Hecks domain's own context cycles (ADR 0207). Four pairs depended on each other when a cycle
# was first refused: Hecks with Agents, Coder, Delivery and QualityControl. Each is untangled, the
# Hecks domain taking over the reactions its attached context held, so `hecks.contextmap` accepts
# none and the wiring has none. This is the ratchet: the list below stays empty.
RSpec.describe "The Hecks domain's context cycles" do
  # The pairs the map may accept. It started with four; each was removed as it was untangled.
  let(:standing) { [] }

  let(:registry) { boot_hecks_in_memory.registry }
  let(:edges) { Hecks::Projections::ContextRelationships.call(registry: registry) }
  let(:accepted) { Hecks::Bluebook::ModelCheck.accepted_cycles([registry.context_map("Hecks")]) }

  it "accepts no cycle beyond the ones that stood before the rule" do
    expect(accepted.keys - standing).to be_empty
  end

  it "has no context cycle in its wiring" do
    expect(Hecks::Bluebook::ModelCheck.context_cycle_findings(edges, accepted: accepted).map(&:to_s)).to be_empty
  end
end
