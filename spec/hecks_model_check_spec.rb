require "spec_helper"
require "hecks/bluebook/model_check"

# The Hecks domain, with every bluebook it attaches, comes through the same static model check the
# pre-push gate runs (`ModelCheckRun.model_check!`) with no finding at all: an error would fail
# the push, and a warning is either fixed or declared with its reason.
RSpec.describe "The Hecks domain's model check" do
  let(:registry) { Hecks.boot(File.join(InMemoryDomain::ROOT, "lib/hecks/hecks"), install_driving: false).registry }

  let(:findings) do
    declarations = registry.bluebooks.values
    events = declarations.flat_map { |declaration| Hecks::Bluebook::ModelCheck.emitted_events(declaration) }.to_set
    owners = declarations.flat_map { |d| d.aggregates.map { |a| [a.hecks_name, d.name.to_s] } }
                         .group_by(&:first).transform_values { |rows| rows.map(&:last).uniq }
    known = (registry.bluebooks.keys + registry.hecksagons.keys).to_set
    declarations.flat_map do |declaration|
      Hecks::Bluebook::ModelCheck.call(declaration, hecksagon: registry.hecksagon(declaration.name),
                                                    known_domains: known, global_emitted_events: events,
                                                    aggregate_owners: owners)
    end
  end

  it "has no errors" do
    expect(findings.select { |f| f.severity == :error }.map(&:to_s)).to be_empty
  end

  it "has no warnings" do
    expect(findings.select { |f| f.severity == :warning }.map(&:to_s)).to be_empty
  end
end
