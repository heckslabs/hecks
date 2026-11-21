# frozen_string_literal: true

require "spec_helper"

# GitHub's REST field names are spoken in one place: `GithubRest` in the GithubEvents bluebook,
# and the hecksagon beside it that translates each reading into a `GithubEvent`. No other
# bluebook or hecksagon declares one, so no domain model reads a GitHub field.
RSpec.describe "the GitHub REST edge" do
  let(:root)   { File.expand_path("..", __dir__) }
  let(:edge)   { File.join(root, "lib/hecks/hecks/github_events") }
  let(:fields) { /merged_at|x-ratelimit|http_status|check_runs/i }

  def declared
    Dir.glob(File.join(root, "lib/**/*.{bluebook,hecksagon}")).reject { |path| path.start_with?(edge) }
  end

  it "keeps GitHub's REST field names out of every other bluebook and hecksagon" do
    expect(declared.select { |path| File.read(path).match?(fields) }).to eq([])
  end

  it "names those fields in the edge bluebook" do
    expect(File.read(File.join(edge, "github_events.bluebook"))).to match(fields)
  end

  it "translates each reading into a GithubEvent in the edge hecksagon" do
    expect(File.read(File.join(edge, "github_events.hecksagon")).scan("trigger GithubEvent::Record").size).to eq(5)
  end

  it "reuses the recorded event, adding no second set of events" do
    expect(File.read(File.join(edge, "github_events.bluebook")).scan("emits GithubEventRecorded").size).to eq(1)
  end
end
