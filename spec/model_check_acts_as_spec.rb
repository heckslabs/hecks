# frozen_string_literal: true

require "spec_helper"

# The model check over `acts_as` (ADR 0216): a role a reaction runs as is only real once an
# authorization provider is attached to grant it.
RSpec.describe Hecks::Bluebook::ModelCheck::ActsAsChecks do
  # A one-policy bluebook whose policy acts as `role`, or states no role when it is nil.
  def bluebook_acting_as(role)
    policy = Hecks::Bluebook::Policy.new(name: "WaterWhenWilted", on_event: "PlantWilted", acts_as: role)
    instance_double(Hecks::Bluebook::Declaration, policies: [policy], provides?: false)
  end

  # A hecksagon that attaches Governance when `governed` is true, and nothing otherwise.
  def hecksagon(governed:) = instance_double(Hecks::Bluebook::Hecksagon, domain: "Plant", attaches?: governed)

  def kinds(bluebook, wiring) = Hecks::Bluebook::ModelCheck.acts_as_findings(bluebook, wiring).map(&:kind)

  it "reports acts_as in a domain that attaches no authorization provider" do
    expect(kinds(bluebook_acting_as("System"), hecksagon(governed: false))).to eq([:ungoverned_acts_as])
  end

  it "reports nothing once Governance is attached" do
    expect(kinds(bluebook_acting_as("System"), hecksagon(governed: true))).to be_empty
  end

  it "reports nothing for a policy that states no role" do
    expect(kinds(bluebook_acting_as(nil), hecksagon(governed: false))).to be_empty
  end

  it "reports nothing when no hecksagon was loaded" do
    expect(kinds(bluebook_acting_as("System"), nil)).to be_empty
  end
end
