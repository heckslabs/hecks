# frozen_string_literal: true

require "spec_helper"
require "hecks/hecks/adapters/git"
require "hecks/hecks/adapters/landing/trailer_refusal"
require_relative "support/trailer_repo"

# A landing refuses a branch whose commits do not name their run, before the rebase and the gate,
# so the refusal reaches the coder and not the boarding.
RSpec.describe "a landing refuses an untrailered commit", :io do
  include TrailerRepo

  let(:work) { Dir.mktmpdir("hecks-landing-trailers") }
  let(:green) { ->(_dir) { Hecks::Adapters::Shell::Result.new('{"status": "completed"}', "", Struct.new(:success?).new(true)) } }

  after { FileUtils.rm_rf(work) }

  def landing_refusal
    Hecks::Adapters::GitLanding::Finisher.new(Hecks::Adapters::Git.new, work, branch: "side", onto: "main", gate: green).prepare
    nil
  rescue Hecks::Adapters::ConsoleCapture::Failure => e
    e.message
  end

  def side_commit(message)
    git("checkout", "-q", "-b", "side")
    commit_file("a", message, at: 3_000)
  end

  it "names the missing Hecks-Run trailer" do
    start(cutoff: 2_000)
    side_commit("change")
    expect(landing_refusal).to include("Hecks-Run")
  end

  it "lands a commit that names its run and work item" do
    start(cutoff: 2_000)
    side_commit("change\n\nHecks-Run: run-1\nHecks-Work: side")
    expect(landing_refusal).to be_nil
  end

  it "asks nothing of a branch whose tree has no hook that writes trailers" do
    start(hook: false, cutoff: 2_000)
    side_commit("change")
    expect(landing_refusal).to be_nil
  end

  it "runs before the settled rebase" do
    names = Hecks::Adapters::GitLanding::Finisher.ancestors.first(3).map(&:name)
    expect(names.index("Hecks::Adapters::Landing::TrailerRefusal")).to be < names.index("Hecks::Adapters::Landing::SettledRebase::Finisher")
  end
end
