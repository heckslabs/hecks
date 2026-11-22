# frozen_string_literal: true

require "spec_helper"
require "hecks/hecks/adapters/main_integration/bisecting"
require_relative "support/trailer_repo"

# A first-bad report names the run that made the culprit merge, read from its commits' trailers.
RSpec.describe "a bisect report names the run" do
  include TrailerRepo

  let(:work) { Dir.mktmpdir("hecks-first-bad-run") }
  let(:repository) { TrailerRepo::MAIN_INTEGRATION::Repository.new(work) }
  let(:bisecting) { TrailerRepo::MAIN_INTEGRATION::Bisecting }

  before do
    start
    land_side("change\n\nHecks-Run: run-42\nHecks-Work: some-item")
  end

  after { FileUtils.rm_rf(work) }

  it "reads the run from the merge's own commits" do
    expect(repository.run_of(git("rev-parse", "HEAD").strip)).to eq("run-42")
  end

  it "says the run in the line a refusal carries" do
    facts = { culprit: "a" * 40, subject: "Merge branch 'x'", run_of_culprit: "run-42", reason: "" }
    expect(bisecting.line(facts)).to include("run run-42")
  end
end
