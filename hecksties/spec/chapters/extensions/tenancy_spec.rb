# Extensions::TenancyChapter paragraph spec
#
# Verifies tenancy internal aggregates exist within the Extensions domain.
#
require "spec_helper"
require "hecks/chapters/extensions"

RSpec.describe Hecks::Chapters::Extensions::TenancyChapter do
  subject(:domain) { Hecks::Chapters::Extensions.definition }

  it "includes OwnershipScopedRepository with ScopeToOwner command" do
    agg = domain.aggregates.find { |a| a.name == "OwnershipScopedRepository" }
    expect(agg).not_to be_nil
    expect(agg.commands.map(&:name)).to include("ScopeToOwner", "VerifyOwnership")
  end

  it "includes TenantScopedRepository with ScopeToTenant command" do
    agg = domain.aggregates.find { |a| a.name == "TenantScopedRepository" }
    expect(agg).not_to be_nil
    expect(agg.commands.map(&:name)).to include("ScopeToTenant", "ForTenant")
  end
end
