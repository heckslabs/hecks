require "spec_helper"
require_relative "support/stable_roll_context"

# A StableRoll reads the box before it changes anything, and stops with the reason on a box that
# is rolling, names no restore point, does not run the service or cannot be read.
RSpec.describe "the Deploy bluebook's StableRoll on a box that is not ready", :io do
  include_context "with a service that follows stable"

  it "stops before the roll while another command runs on the box", :aggregate_failures do
    File.write(File.join(runner.dir, "in_progress"), "cmd-roll\n")
    roll = follow_stable("cms-at-busy")

    expect(roll.values_at("status", "reason")).to eq(["stopped", "a command is still running on the box"])
    expect(service_roll_status("cms-at-busy")).to be_nil
  end

  it "stops before the roll when the box names no restore point" do
    roll = follow_stable("cms-at-unanchored", env: { "STUB_BACKUP_DAYS" => "None" })

    expect(roll.values_at("status", "reason")).to eq(["stopped", "the box names no restore point (ADR 0105)"])
  end

  it "stops before the roll when the service does not run on the box" do
    box_runs("website" => "website-old")
    roll = follow_stable("cms-at-absent")

    expect(roll.values_at("status", "reason")).to eq(["stopped", "the service is not running on the box"])
  end

  it "stops with the reason when the box cannot be read" do
    File.write(File.join(project, "deploy-box.sh"), "#!/bin/bash\n")
    roll = follow_stable("cms-at-unreadable")

    expect(roll.values_at("status", "reason")).to match(["stopped", /assigns no BOX_STACK/])
  end
end
