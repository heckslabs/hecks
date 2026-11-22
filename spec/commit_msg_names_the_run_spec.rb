# frozen_string_literal: true

require "spec_helper"
require_relative "support/run_trailer_repo"

# The commit-msg hook records the run, role and work item on a commit and never refuses.
RSpec.describe "the commit-msg hook names the run", :io do
  include RunTrailerRepo

  let(:work) { Dir.mktmpdir("hecks-commit-run") }
  let(:agent) { { "HECKS_RUN_KEY" => "run-7", "HECKS_ROLE" => "coder" } }

  before { hooked_repository }

  after { FileUtils.rm_rf(work) }

  it "adds the run, the role and the work item from the branch" do
    expect(commit(agent)).to include("Hecks-Run: run-7", "Hecks-Role: coder", "Hecks-Work: the-item")
  end

  it "records an owner only when the owner says so", :aggregate_failures do
    message = commit("HECKS_OWNER" => "1")
    expect(message).to include("Hecks-Run: owner")
    expect(message).not_to include("Hecks-Work")
  end

  it "writes no run when nothing says who is committing" do
    expect(commit({})).not_to include("Hecks-Run")
  end
end
