require "spec_helper"
require "hecks/hecks/adapters/landing_claim"

# The Delivery hecksagon's FindWorkWhenTheJobsLandingIsRefused: which refusal of a landing finds its
# work item to plan again. A refusal is the free text of a ConsoleCapture::Failure.
RSpec.describe "the translation that plans a refused landing's work item again" do
  # The refusals a coder fixes, one per prefix the landing and carry code raises.
  FIXABLE_REFUSALS = [
    "conflict: rebasing a onto main stopped",
    "gate red: the gate failed in /tmp/x: rubocop: 1 offense",
    "impacted specs red: spec/a_spec.rb failed",
    "shallow check red: syntax error in a.rb",
    "unsaved work: the checkout has uncommitted files",
    "no gate: the project binds none",
    "no checkout to judge: the shipment names none",
    "a lacks 2 commits that origin/main has: pull main first"
  ].freeze

  # What a landing says when it will be tried again or is already running: the item stays done.
  TRANSIENT_REFUSALS = [
    "landing in flight: pid 7 holds this checkout",
    "queue busy: a is not landed: x; land again when the line clears"
  ].freeze

  let(:registry) { boot_hecks_in_memory.registry }

  def policy = registry.bluebook("Delivery").policies.find { |p| p.name == "FindWorkWhenTheJobsLandingIsRefused" }

  def finds?(text)
    payload = { refusal: { value: text } }
    Hecks::Bluebook::Expression::Evaluator.call_rule(policy.where_rule, {}, payload)
  end

  it "finds the work item for every refusal a coder fixes", :aggregate_failures do
    FIXABLE_REFUSALS.each { |text| expect(finds?(text)).to be(true), text }
  end

  it "leaves the work item done for a transient refusal", :aggregate_failures do
    TRANSIENT_REFUSALS.each { |text| expect(finds?(text)).to be(false), text }
  end

  it "names the same text the landing claim refuses with" do
    expect(policy.where).to include(Hecks::Adapters::LandingClaim::REFUSAL)
  end
end
