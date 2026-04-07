require "spec_helper"
require "hecks/chapters/binding"

RSpec.describe Hecks::Chapters::Binding::ErrorsParagraph do
  subject(:domain) { Hecks::Chapters::Binding.definition }

  let(:names) { domain.aggregates.map(&:name) }

  it "includes error aggregates" do
    expect(names).to include("Error", "ValidationError", "GuardRejected",
                             "PreconditionError", "DomainLoadError")
  end

  it "Error has Raise command" do
    agg = domain.aggregates.find { |a| a.name == "Error" }
    expect(agg.commands.map(&:name)).to include("Throw")
  end

  it "GateAccessDenied has Raise command" do
    agg = domain.aggregates.find { |a| a.name == "GateAccessDenied" }
    expect(agg).not_to be_nil
    expect(agg.commands.map(&:name)).to include("Throw")
  end

  it "contributes at least 15 error aggregates" do
    error_names = %w[Error ValidationError GuardRejected PreconditionError
                     PostconditionError DomainLoadError InvalidDomainVersion
                     MigrationError ConfigurationError GateAccessDenied
                     Unauthenticated Unauthorized RateLimitExceeded
                     ConcurrencyError PathTraversalDetected ReferenceNotFound
                     ReferenceAccessDenied]
    present = error_names.select { |n| names.include?(n) }
    expect(present.size).to be >= 15
  end
end
