require "spec_helper"
require "hecks/bluebook/model_check"

# The Hecks domain's own context cycles (ADR 0207). Four pairs depended on each other before a
# cycle was refused; each ran through a context that moved out with the development pipeline
# (ADR 0205), so none stands now. This is the ratchet: the map accepts no cycle, and none is found.
RSpec.describe "The Hecks domain's context cycles" do
  let(:registry) { boot_hecks_in_memory.registry }
  let(:edges) { Hecks::Projections::ContextRelationships.call(registry: registry) }
  let(:accepted) { Hecks::Bluebook::ModelCheck.accepted_cycles([registry.context_map("Hecks")]) }

  it "accepts no cycle" do
    expect(accepted.keys).to be_empty
  end

  it "has no cycle, with nothing accepted" do
    expect(Hecks::Bluebook::ModelCheck.context_cycle_findings(edges).map(&:to_s)).to be_empty
  end
end
