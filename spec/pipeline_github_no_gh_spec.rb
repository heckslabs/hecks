# frozen_string_literal: true

require "spec_helper"
require "hecks/pipeline_board/adapters/pipeline_github"

# The guard: CI, the train's CI and the train's flakes are projected from recorded runs, so a board
# request or a draw makes no `gh` call, whatever is or is not recorded. The readers that remain on
# `gh` (open and train pull requests, the release, the repository address) have no record yet.
RSpec.describe Hecks::Adapters::PipelineGitHub, "#ci_runs and the other recorded readers" do
  let(:asked) { [] }
  let(:readers) { %i[ci_runs slowest_jobs train_ci_runs train_slowest_jobs train_flakes] }

  def adapter(rows)
    seats = Struct.new(:rows) { def records(_domain, _name) = rows }.new(rows)
    described_class.new(settings: { gh: ->(*args) { (asked << args) && {} }, seats: -> { seats }, ttl: 0 })
  end

  def draw(subject) = readers.each { |reader| read(subject, reader) }

  def read(subject, reader)
    subject.public_send(reader)
  rescue Hecks::Adapters::PipelineBoard::Unavailable
    nil
  end

  it "asks gh for nothing when no run is recorded" do
    draw(adapter([]))
    expect(asked).to be_empty
  end

  it "asks gh for nothing when runs are recorded" do
    row = { sighting: "1-1-done", ci_run: "1", attempt: 1, state: "completed", lane: "train", commit: "abc", branch: "train/x",
            conclusion: "success", pushed_at: Time.now.utc.iso8601, wall_minutes: 1.0, failed_jobs: 0, jobs: "[]" }
    draw(adapter([row, row.merge(lane: "main")]))
    expect(asked).to be_empty
  end

  it "names the readers still on gh: the open pull requests, the release and the address" do
    expect(described_class.public_instance_methods(false)).to include(:open_prs, :train_prs, :latest_release, :repo_url)
  end
end
