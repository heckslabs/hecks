require "spec_helper"
require "fileutils"
require_relative "support/red_episode_helpers"
require_relative "support/revert_landing_repo"

# A revert of a named culprit is one verb: the revert commit says which merge it undoes, the train
# the culprit rode is closed, and a merge with no Work item of its own is filed to land again at
# priority now, naming the merge and the branch. The episode refuses a failure that origin/main
# shares. Episodes run in Memory; the revert commit is made in a throwaway repository.
RSpec.describe "reverting a named culprit in one verb" do
  include RedEpisodeHelpers

  it "refuses a culprit whose failure also reproduces on origin/main" do
    expect { decide("Revert", "v1", at: 0, culprit: "m-v1", reproduced: true) }.to raise_error(/origin.main does not share the failure/)
  end

  it "closes the train the culprit rode when the episode starts reverting" do
    heard = hear("EpisodeReverting", "RedEpisode", key("v2"), { culprit: value("m-v2"), landed: value("l-v2"), subject: value("red") })
    expect(heard.map { |row| row[:policy] }).to include("CloseTheTrainOfARevertedCulprit")
  end

  it "files the work to land again, at priority now, when the merge has no Work item" do
    heard = hear("EpisodeRevertMade", "RedEpisode", key("v3"), { work: value(""), branch: value("feature-v3"), report: value("r") })
    expect(heard.map { |row| row[:policy] }).to include("FileTheRelandOfAnUnplannedRevert",
                                                         "PrioritizeTheRelandOfAnUnplannedRevert")
  end

  it "files nothing new when the merge has its Work item" do
    heard = hear("EpisodeRevertMade", "RedEpisode", key("v4"), { work: value("feature-v4"), branch: value("feature-v4"), report: value("r") })
    expect(heard.map { |row| row[:policy] }).not_to include("FileTheRelandOfAnUnplannedRevert")
  end

  context "with the revert commit made" do
    include RevertLandingRepo

    after { FileUtils.rm_rf(File.dirname(work)) }

    it "names the merge it undoes in a Hecks-Revert-Of trailer" do
      start_repo
      merge = land("one")
      git("log", "-1", "--format=%(trailers:key=Hecks-Revert-Of,valueonly)", revert(merge)[:reverted])
        .then { |trailer| expect(trailer).to eq(merge) }
    end
  end
end
