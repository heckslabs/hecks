require "json"
require_relative "replaced_runs_fixtures"

# A fake GitHub holding one open train pull request whose only check failed.
module RedPullRequestHost
  include ReplacedRunsFixtures

  def pull
    { "number" => 1354, "state" => "OPEN", "commits" => [{ "oid" => tip }],
      "statusCheckRollup" => [check(1, conclusion: "FAILURE")] }
  end

  def listed = [run(1, "2026-11-11T20:21:21Z").merge("attempt" => 1)]

  # @param readable [Boolean] whether `gh run view` answers; false answers a 502
  def host(readable:)
    lambda do |argv, **|
      return [true, JSON.generate(pull)] if argv[1] == "pr"
      return [false, "HTTP 502: Bad Gateway"] if argv[2] == "view" && !readable

      [true, JSON.generate(argv[2] == "view" ? { "jobs" => [] } : listed)]
    end
  end
end
