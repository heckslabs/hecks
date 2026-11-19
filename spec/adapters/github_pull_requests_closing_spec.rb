require "hecks"
require "json"
require_relative "../../lib/hecks/hecks/adapters/github_pull_requests"

# The `Shut` ask over a recorder of `gh` arguments: an open pull request is closed with its
# comment, and one that is not open, or a close with no comment, is refused before any close.
RSpec.describe Hecks::Adapters::GithubPullRequests::Closing do
  subject(:pulls) { Hecks::Adapters::GithubPullRequests.new(runner: runner) }

  let(:calls) { [] }
  let(:state) { "OPEN" }
  let(:runner) do
    lambda do |args|
      calls << args
      args.first(2) == %w[pr view] ? [JSON.generate("state" => state), "", true] : ["", "", true]
    end
  end

  def shut(comment = "superseded by #9") = pulls.shut(number: { value: "7" }, comment: { value: comment })

  it "closes the pull request with its comment as one argument, and names it", :aggregate_failures do
    expect(shut[:report][:value]).to eq("closed #7: superseded by #9")
    expect(calls.last).to eq(["pr", "close", "7", "--comment", "superseded by #9"])
  end

  it "refuses a close with no comment, and asks GitHub nothing", :aggregate_failures do
    expect { shut("  ") }.to raise_error(Hecks::Adapters::ConsoleCapture::Failure, /no comment/)
    expect(calls).to be_empty
  end

  context "when the pull request is merged" do
    let(:state) { "MERGED" }

    it "refuses it and closes nothing", :aggregate_failures do
      expect { shut }.to raise_error(Hecks::Adapters::ConsoleCapture::Failure, /not open \(MERGED\)/)
      expect(calls.map { |args| args.first(2) }).not_to include(%w[pr close])
    end
  end
end
