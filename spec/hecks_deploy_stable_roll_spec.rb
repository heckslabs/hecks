require "spec_helper"
require_relative "support/stable_roll_context"

# `hecks deploy stable_roll.request!`: the Deploy bluebook's StableRoll holds a service whose
# auto-roll switch is off, and otherwise reads the box, rolls through ServiceRoll and its smoke,
# and ends rolled or stopped. Nothing reaches AWS or GitHub. The box that is not ready is in
# `hecks_deploy_stable_roll_box_spec.rb`.
RSpec.describe "the Deploy bluebook's StableRoll", :io do
  include_context "with a service that follows stable"

  it "rolls a switched-on service and records the tag it ran before and the restore point", :aggregate_failures do
    roll = follow_stable("cms-at-rolled")

    expect(roll.values_at("status", "previous_tag", "box")).to eq(%w[rolled cms-old i-0abc])
    expect(roll.fetch("restore_point")).to include("restorable to", "backups kept 7 days")
    expect(service_roll_status("cms-at-rolled")).to eq("verified")
  end

  it "holds a switched-off service, reading and rolling nothing", :aggregate_failures do
    roll = follow_stable("cms-at-held", auto_roll: false)

    expect(roll.values_at("status", "reason")).to eq(["held", "auto-roll is off for this service"])
    expect(runner.calls).to be_empty
  end

  it "stops, keeping the way back, when the smoke after the roll is red", :aggregate_failures do
    roll = follow_stable("cms-at-red", env: { "STUB_CONCLUSION" => "failure" })

    expect(roll.values_at("status", "previous_tag")).to eq(%w[stopped cms-old])
    expect(roll.fetch("reason")).to include("smoke ended 22")
    expect(roll.fetch("restore_point")).to include("restorable to")
  end

  it "stops when the roll itself does not take" do
    roll = follow_stable("cms-at-flagged", env: { "EXISTING_TAG" => nil })

    expect(roll.values_at("status", "reason")).to match(["stopped", /service roll ended 31/])
  end
end
