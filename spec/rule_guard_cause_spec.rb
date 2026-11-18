# frozen_string_literal: true

require "spec_helper"
require_relative "support/missing_value_guards"

# A faulted gate run is filed as a finding of its run when it names no cause, and by its cause
# when it names one. The conditions test a missing cause with `.value == nil`.
RSpec.describe "The Tickets policies on a faulted gate's cause" do
  include MissingValueGuards

  let(:tickets) { MissingValueGuards.bluebook("lib/hecks/tickets/bluebook", "Tickets") }

  def policy(name)
    tickets.policies.find { |held| held.hecks_name == name }
  end

  def fired(payload)
    %w[ReportWhenGateFaulted ReportWhenGateFaultedByCause ReopenWorkWhenGateFaultedAgain]
      .map { |name| fires?(policy(name), payload) }
  end

  it "files a fault with a missing or empty cause by its run", :aggregate_failures do
    expect(fired({ cause: nil })).to eq([true, false, false])
    expect(fired({ cause: { value: nil } })).to eq([true, false, false])
    expect(fired({ cause: { value: "" } })).to eq([true, false, false])
  end

  it "files and reopens a fault with a cause by its cause" do
    expect(fired({ cause: { value: "gate-quick-rubocop" } })).to eq([false, true, true])
  end

  it "reports the impacted specs a shallow check left unrun, and nothing when it ran them all", :aggregate_failures do
    overran = policy("ReportWhenImpactedSpecsOverran")
    expect(fires?(overran, { unrun: { value: "spec/a_spec.rb" } })).to be(true)
    [nil, { value: nil }, { value: "" }].each { |none| expect(fires?(overran, { unrun: none })).to be(false) }
  end
end
