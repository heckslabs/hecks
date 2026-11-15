# frozen_string_literal: true

require "spec_helper"
require_relative "support/beat_places"

# One beat runs at a time: a beat that finds another process holding the place is refused at once
# and runs no policy, and the kernel frees the place when its holder dies.
RSpec.describe "a heartbeat's single flight" do
  include BeatPlaces

  let(:dir) { Dir.mktmpdir("beat-place") }
  let(:facts) { beat_against_holder(dir) }

  after { clean_place(dir) }

  context "when another process holds the place" do
    it("is declined", :aggregate_failures) do
      expect(facts[:names]).to include("BeatDeclined")
      expect(facts[:names]).not_to include("Beaten", "SweepRequested")
    end

    it("is declined in under a second") { expect(facts[:seconds]).to be < 1 }

    it("names the holder") { expect(facts[:refusal]).to match(/\Abeat already running \(pid #{facts[:pid]}, age \d+ s\)\z/) }
  end

  context "when the holder is killed" do
    it("beats and runs its policies", :aggregate_failures) do
      names = beat_after_holder_killed(dir)

      expect(names).to include("Beaten", "SweepRequested")
      expect(names).not_to include("BeatDeclined")
    end

    it("is not refused by the beat before it in the same process") do
      beat_names(dir, "beat-one")

      expect(beat_names(dir, "beat-two")).to include("Beaten")
    end
  end
end
