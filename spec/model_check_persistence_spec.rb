# frozen_string_literal: true

require "spec_helper"

# The model check over persistence: a domain that keeps some aggregates in a store and leaves
# another in Memory, with no default and no word, has lost that aggregate's records in silence.
RSpec.describe Hecks::Bluebook::ModelCheck::PersistenceChecks do
  def bluebook = instance_double(Hecks::Bluebook::Declaration, name: "Plant", aggregates: [bloom, pot])

  def bloom = instance_double(Hecks::Bluebook::Aggregate, hecks_name: "Bloom")

  def pot = instance_double(Hecks::Bluebook::Aggregate, hecks_name: "Pot")

  def bind(aggregate, adapter, verb: "persisted_by")
    Hecks::Bluebook::Bind.new(aggregate: aggregate, verb: verb, adapter: adapter)
  end

  def wiring(*binds) = Hecks::Bluebook::Hecksagon.new(domain: "Plant", binds: binds)

  def findings(*binds) = Hecks::Bluebook::ModelCheck.persistence_findings(bluebook, wiring(*binds))

  it "reports the aggregate a persisting domain leaves in Memory, naming the line to add" do
    expect(findings(bind("Plant::Bloom", "Heki")).map(&:message)).to contain_exactly(
      a_string_including("Pot", "Plant::Pot.persisted_by(\"Heki\")")
    )
  end

  it "reports nothing once the aggregate declares Memory" do
    expect(findings(bind("Plant::Bloom", "Heki"), bind("Plant::Pot", "Memory"))).to be_empty
  end

  it "reports nothing for a domain that wires nothing" do
    expect(Hecks::Bluebook::ModelCheck.persistence_findings(bluebook, nil) + findings).to be_empty
  end

  it "reports nothing when a default covers the rest" do
    expect(findings(bind("Plant::Bloom", "Heki"), bind(nil, "Memory"))).to be_empty
  end
end
