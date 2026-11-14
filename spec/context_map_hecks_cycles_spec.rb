require "spec_helper"
require "hecks/bluebook/model_check"

# The Hecks domain's own context cycles (ADR 0207). Four pairs depended on each other before a
# cycle was refused, so `hecks.contextmap` accepts each on its relationship and `model_check`
# reports it as deprecated. This is the ratchet: the list below may lose a pair and never gain one.
RSpec.describe "The Hecks domain's context cycles" do
  # The pairs accepted when cycles were first refused. Remove one when it is untangled.
  let(:standing) { [%w[Agents Hecks], %w[Coder Hecks], %w[Delivery Hecks], %w[Hecks QualityControl]] }

  let(:registry) { boot_hecks_in_memory.registry }
  let(:edges) { Hecks::Projections::ContextRelationships.call(registry: registry) }
  let(:accepted) { Hecks::Bluebook::ModelCheck.accepted_cycles([registry.context_map("Hecks")]) }
  let(:found) { Hecks::Bluebook::ModelCheck.context_cycle_findings(edges, accepted: accepted) }

  it "accepts no cycle beyond the ones that stood before the rule" do
    expect(accepted.keys - standing).to be_empty
  end

  it "has no cycle the map does not accept" do
    expect(found.select { |finding| finding.severity == :error }.map(&:to_s)).to be_empty
  end

  it "reports each accepted cycle as deprecated, with the release that refuses it", :aggregate_failures do
    expect(found.map(&:kind).uniq).to eq([:context_cycle])
    expect(found.map(&:message)).to all(include("deprecated and refused from 8.0.0"))
  end

  it "refuses the same wiring once the map stops accepting it" do
    refused = Hecks::Bluebook::ModelCheck.context_cycle_findings(edges)
    expect(refused.map { |finding| [finding.severity, finding.subject] })
      .to eq([[:error, "Agents <-> Coder <-> Delivery <-> Hecks <-> QualityControl"]])
  end
end
