require "spec_helper"
require "tmpdir"
require "hecks/hecks/adapters/dispatching"
require_relative "support/impediment_looks"

# The impediment view names the pipeline patterns the scrum master wakes on: a beat declined
# with no beat since, and landings refused with no landing since. Each is one impediment, however
# many refusals follow, and gone once the beat or the landing comes.
RSpec.describe "StallWatch impediments: the pipeline patterns" do
  include_context "with a stall watch tap"
  include ImpedimentLooks

  let(:declined) { ["BeatDeclined", "beat-1", 12, "Hecks::Heartbeat"] }
  let(:refused)  { ["LandingRefused", "land-1", 35, "Delivery::Landing"] }

  it "lists a beat declined for over ten minutes", :aggregate_failures do
    write_sources([declined])

    expect(row_of("beat-declined")).to include(subject: "beat-1", waited: 12, fixer: "orchestrator")
    expect(row_of("beat-declined")[:cleared_by]).to eq("help")
  end

  it "leaves a beat declined only just out" do
    write_sources([["BeatDeclined", "beat-1", 4, "Hecks::Heartbeat"]])
    expect(kinds).not_to include("beat-declined")
  end

  it "leaves the declined beat once a beat is taken" do
    write_sources([declined, ["Beaten", "beat-2", 1, "Hecks::Heartbeat"]])
    expect(kinds).not_to include("beat-declined")
  end

  it "is one impediment from the first refusal since the last landing", :aggregate_failures do
    write_sources([refused, ["LandingRefused", "land-2", 20, "Delivery::Landing"]])

    expect(kinds.count("landings-refused")).to eq(1)
    expect(row_of("landings-refused")).to include(subject: "land-1", waited: 35)
  end

  it "leaves the refused landings once a branch lands" do
    write_sources([refused, ["BranchLanded", "land-3", 1, "Delivery::Landing"]])
    expect(kinds).not_to include("landings-refused")
  end
end
