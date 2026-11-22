# frozen_string_literal: true

require "spec_helper"
require_relative "support/run_trailer_repo"

# What the commit-msg hook leaves alone when it writes the trailers.
RSpec.describe "the commit-msg hook leaves what is there", :io do
  include RunTrailerRepo

  let(:work) { Dir.mktmpdir("hecks-commit-run") }
  let(:agent) { { "HECKS_RUN_KEY" => "run-7", "HECKS_ROLE" => "coder" } }

  before { hooked_repository }

  after { FileUtils.rm_rf(work) }

  it "keeps a trailer the message already carries", :aggregate_failures do
    message = commit(agent, "x\n\nHecks-Run: other")
    expect(message).to include("Hecks-Run: other")
    expect(message.scan("Hecks-Run").size).to eq(1)
  end

  it "leaves the author as it was" do
    commit(agent)
    expect(git("log", "-1", "--format=%an <%ae>").first.strip).to eq("Miette <miette@embryonaut.ai>")
  end

  it "still strips a Claude trailer" do
    expect(commit(agent, "x\n\nCo-Authored-By: Claude <a@b.c>")).not_to include("Claude")
  end
end
