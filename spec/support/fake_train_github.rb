# A scripted GitHub for the train pull request specs: one open pull request with red checks, one CI
# run at the given attempt, and the open pull requests a sweep lists. It answers `gh` as the
# `CiRuns` and `GithubPullRequests` adapters call it, and remembers every call.
class FakeTrainGithub
  # A log from a shard that ran the specs and one example failed.
  SPEC_LOG = "Failures:\n\n  1) a real example fails\n     Failure/Error: expect(1).to eq(2)\n\n" \
             "1 examples, 1 failures\nrspec ./spec/real_spec.rb:3 # a real example fails".freeze

  # A log from a shard that failed in CI setup, before any spec ran (PR 1335, 2026-11-11).
  SETUP_LOG = "apt install of zsh failed or timed out (attempt 3 of 3)\n" \
              "##[error]Process completed with exit code 1".freeze

  attr_accessor :attempt, :log, :pulls, :number
  attr_reader :calls

  def initialize
    @attempt = 1
    @number = rand(2000..900_000)
    @log = SPEC_LOG
    @calls = []
    @pulls = []
  end

  # The runner the `CiRuns` adapter takes: `(argv, chdir:)` answering `[ok, output]`.
  def call(argv, **)
    @calls << argv.join(" ")
    [true, answer(argv)]
  end

  # The runner the `GithubPullRequests` adapter takes: `(argv)` answering `[out, err, ok]`.
  def gh(argv) = [answer(["gh", *argv]), "", true]

  # The runner for `git` in a sweep: `held` maps a commit to the tips that contain it.
  def git(held: {})
    lambda do |argv|
      @calls << "git #{argv.join(" ")}"
      [argv.first != "merge-base" || Array(held[argv[2]]).include?(argv[3]), ""]
    end
  end

  def reruns = @calls.grep(/run rerun/)

  def closed = @calls.grep(/pr close/)

  private

  def answer(argv)
    case argv[1..2]
    when %w[pr view] then view.to_json
    when %w[run list] then [{ databaseId: 77, attempt: @attempt }].to_json
    when %w[run view] then argv.include?("--log-failed") ? @log : jobs.to_json
    when %w[pr list] then @pulls.to_json
    else ""
    end
  end

  def jobs
    { jobs: [{ name: "rspec shard 1", conclusion: "failure",
               steps: [{ name: "Install zsh", conclusion: "failure" }, { name: "Checkout", conclusion: "success" }] }] }
  end

  def view
    { number: @number, state: "OPEN", commits: [{ oid: "b" * 40, messageHeadline: "fix" }],
      statusCheckRollup: [{ name: "rspec", status: "COMPLETED", conclusion: "FAILURE" }] }
  end
end
