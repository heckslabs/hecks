require "spec_helper"

# A `Postgres` bind in a hecksagon that sets `revisions` is built with the revision layout (ADR 0182).
# The choice is read from the registry's hecksagon, so the spec stands in a registry that answers
# only that, and never connects to a database.
RSpec.describe "revisions, choosing the Postgres layout" do
  let(:factory) { Hecks::Ports::Persistence::RepositoryFactory }
  let(:bind)    { Hecks::Bluebook::Bind.new(aggregate: "Loan", verb: "persisted_by", adapter: "Postgres") }

  def registry_with(revisions)
    hecksagon = instance_double(Hecks::Bluebook::Hecksagon, revisions?: revisions)
    instance_double(Hecks::Runtime::Registry, hecksagon: hecksagon)
  end

  it "selects the revision layout for a Postgres bind when the hecksagon sets revisions" do
    expect(factory.send(:revision_domain?, registry_with(true), "Lending", bind)).to be true
  end

  it "keeps the table layout for a Postgres bind when revisions is left out" do
    expect(factory.send(:revision_domain?, registry_with(false), "Lending", bind)).to be false
  end

  it "leaves a bind on any other adapter alone, whatever the hecksagon sets" do
    memory = Hecks::Bluebook::Bind.new(aggregate: "Loan", verb: "persisted_by", adapter: "Memory")

    expect(factory.send(:revision_domain?, registry_with(true), "Lending", memory)).to be false
  end
end
