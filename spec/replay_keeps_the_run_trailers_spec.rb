# frozen_string_literal: true

require "spec_helper"
require_relative "support/trailer_repo"

# The replay a landing and a main pull make carries each commit's run trailers over unchanged.
RSpec.describe "a replayed commit keeps the run that made it", :io do
  include TrailerRepo

  let(:work) { Dir.mktmpdir("hecks-replay-trailers") }

  after { FileUtils.rm_rf(work) }

  def side_rebased_onto_moved_main
    start
    git("checkout", "-q", "-b", "side")
    commit_file("a", "change\n\nHecks-Run: run-1\nHecks-Work: side")
    git("checkout", "-q", "main")
    commit_file("b", "moved")
    git("checkout", "-q", "side")
    git("rebase", "main")
  end

  it "keeps Hecks-Run and Hecks-Work through a rebase onto a moved main" do
    side_rebased_onto_moved_main
    expect(git("log", "-1", "--format=%B")).to include("Hecks-Run: run-1", "Hecks-Work: side")
  end
end
