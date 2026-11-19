require_relative "rest_pull_view"

# A scripted GitHub for the train pull request specs: one open pull request with red checks, one CI
# run at the given attempt, and the open pull requests a sweep lists. It answers `gh` as the
# `CiRuns` and `GithubPullRequests` adapters call it, and remembers every call.
class FakeTrainGithub
  # A log from a shard that ran the specs and one example failed.
  SPEC_LOG = "Failures:\n\n  1) a real example fails\n     Failure/Error: expect(1).to eq(2)\n\n" \
             "1 examples, 1 failures\nrspec ./spec/real_spec.rb:3 # a real example fails".freeze

  # A log from a shard that failed in CI setup (an apt install), before any spec ran.
  SETUP_LOG = "apt install of zsh failed or timed out (attempt 3 of 3)\n" \
              "##[error]Process completed with exit code 1".freeze

  # A path a train pull request changes that no spec exercises, so a failing spec is unrelated.
  UNRELATED = "lib/hecks/hecks/adapters/ci_runs/no_spec_reads_this_path.txt".freeze

  attr_accessor :attempt, :log, :pulls, :number, :failed_jobs, :state, :rollup, :jobs_error, :log_error, :files
  attr_reader :calls

  def initialize
    @attempt = 1
    @state = "OPEN"
    @number = rand(2000..900_000)
    @log = SPEC_LOG
    @calls = []
    @pulls = []
    @files = [UNRELATED]
  end

  # The runner the `CiRuns` adapter takes: `(argv, chdir:)` answering `[ok, output]`.
  def call(argv, **)
    @calls << argv.join(" ")
    return [false, "HTTP 502: Server Error"] if broken?(argv)

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

  # Every rerun asked: of a run's failed jobs (`gh run rerun --failed`) or of one job by itself.
  def reruns = @calls.grep(%r{run rerun|actions/jobs/\d+/rerun})

  def job_reruns = @calls.grep(%r{actions/jobs/\d+/rerun})

  def closed = @calls.grep(/pr close/)

  private

  # GitHub's jobs endpoint answering 502: the job listing (`jobs_error`) or the whole failed log
  # (`log_error`) cannot be read, while the pull request itself can.
  def broken?(argv)
    return @files.nil? if argv.last.to_s.match?(%r{/pulls/\d+/files})
    return false unless argv[1..2] == %w[run view]
    return @jobs_error if argv.include?("--json")

    @log_error && argv.include?("--log-failed") && !argv.include?("--job")
  end

  def answer(argv)
    rest_answer(argv.last.to_s) || listed_answer(argv)
  end

  # The REST calls only this fake answers: the pull request's files and a rerun of one job.
  def rest_answer(path)
    return files_answer if path.match?(%r{/pulls/\d+/files})

    "{}" if path.match?(%r{actions/jobs/\d+/rerun})
  end

  def listed_answer(argv)
    return RestPullView.open_answer(argv, @pulls) || RestPullView.answer(argv, view) if RestPullView.api?(argv)

    case argv[1..2]
    when %w[pr view] then view.to_json
    when %w[run list] then [{ databaseId: 77, attempt: @attempt }].to_json
    when %w[run view] then argv.include?("--log-failed") ? failed_log(argv) : jobs.to_json
    else ""
    end
  end

  # The files the pull request changes, as `gh api --paginate --slurp` prints them; `files` nil
  # makes the read fail.
  def files_answer = [@files.map { |path| { filename: path } }].to_json

  # The failed jobs of the run: `failed_jobs` rows of `name`, `id`, `log` and `step`, or one job
  # that holds `log`.
  def rows = @failed_jobs || [{ name: "rspec shard 1", id: 1, log: @log, step: "Install zsh" }]

  def failed_log(argv)
    job = argv.index("--job")
    return rows.map { |row| row[:log] }.join("\n") unless job

    rows.find { |row| row[:id].to_s == argv[job + 1] }[:log]
  end

  def jobs = { jobs: rows.map { |row| job_row(row) } }

  def job_row(row)
    { databaseId: row[:id], name: row[:name], conclusion: "failure",
      steps: [{ name: row[:step], conclusion: "failure" }, { name: "Checkout", conclusion: "success" }] }
  end

  def view
    { number: @number, state: @state, commits: [{ oid: "b" * 40, messageHeadline: "fix" }],
      statusCheckRollup: @rollup || [{ name: "rspec", status: "COMPLETED", conclusion: "FAILURE" }] }
  end
end
