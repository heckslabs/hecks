require "time"
require_relative "fake_train_github"

# A scripted GitHub whose train pull request lists no check and whose CI run sits queued, as in an
# Actions outage. It opened `opened` minutes ago, and closing, reopening and commenting change it
# the way GitHub would, so a later read sees the marker comments.
class FakeUnstartedGithub < FakeTrainGithub
  attr_accessor :run_status, :comments
  attr_writer :opened

  def initialize
    super
    @rollup = []
    @run_status = "queued"
    @comments = []
    @opened = 15
  end

  # The `GithubPullRequests` runner, remembering each call as the `CiRuns` one does.
  def gh(argv)
    calls << "gh #{argv.join(" ")}"
    super
  end

  # @return [Array<String>] the calls that changed the pull request
  def touched = calls.grep(/pr (close|reopen|comment|merge)/)

  def reopens = calls.grep(/pr reopen/)

  private

  def answer(argv)
    case argv[1..2]
    when %w[run list] then runs.to_json
    when %w[pr comment] then comment(argv)
    when %w[pr close] then settle("CLOSED")
    when %w[pr reopen] then settle("OPEN")
    else super
    end
  end

  def runs
    [{ databaseId: 77, attempt: attempt, workflowName: "CI", event: "pull_request", headSha: "b" * 40,
       status: run_status, createdAt: (Time.now.utc - 60).iso8601 }]
  end

  def comment(argv)
    @comments << { body: argv[argv.index("--body") + 1] }
    ""
  end

  def settle(state)
    self.state = state
    ""
  end

  def view = super.merge(createdAt: (Time.now.utc - (@opened * 60)).iso8601, comments: @comments)
end
