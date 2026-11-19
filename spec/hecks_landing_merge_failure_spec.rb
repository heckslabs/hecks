require "spec_helper"
require "hecks/hecks/adapters/delivery_library"
Hecks::Adapters::DeliveryLibrary.require("git_landing")
require_relative "support/merge_refusal_repository"

# A landing's merge that fails says why: a true conflict names its files, and a merge commit a
# hook refuses carries git's own words and is not called a conflict. Each example builds its own
# throwaway repository, with no global identity, as a CI runner has.
RSpec.describe Hecks::Adapters::GitLanding::Merger, "#land" do
  include MergeRefusalRepository

  let(:repo) { File.join(File.realpath(Dir.mktmpdir("hecks-merge-failure")), "main") }

  after { FileUtils.remove_entry(File.dirname(repo)) }

  it "names the files of a true conflict" do
    branch_off("README", "from a")
    commit("README", "from main")
    expect(refusal).to include("conflicts in README; nothing changed")
  end

  it "carries what a hook that refuses the merge commit printed, and does not say conflicts" do
    branch_off("a.txt", "a")
    refuse_merge_commits
    expect(refusal).to match(/\Amerging a into main failed: [^;]*hook says no/)
  end
end
