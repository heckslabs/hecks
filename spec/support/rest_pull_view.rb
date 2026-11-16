# frozen_string_literal: true

require "json"

# Answers the REST reads `GhRest` makes of one pull request (`gh api .../pulls?...`, its
# commits, comments, check runs and statuses) from the same pull request a spec scripts in the
# shape `gh pr view --json` gave, so a fake `gh` keeps one description of its pull request.
module RestPullView
  SHA = "c" * 40

  module_function

  # @param argv [Array<String>] the whole command, `["gh", "api", ...]`
  # @return [Boolean] whether it is a REST read of a pull request
  def api?(argv) = argv[1] == "api" && argv.last.to_s.match?(%r{\Arepos/\{owner\}/\{repo\}/(pulls|issues|commits)})

  # @param argv [Array<String>] the pull request list read, `...pulls?state=all&head=...:<branch>`
  # @return [String] the branch it asks for
  def branch(argv) = argv.last.to_s[/head=\{owner\}:([^&]+)/, 1].to_s

  # @param argv [Array<String>] the command
  # @param pull [Hash, nil] the pull request as `gh pr view --json` answers it, nil for none
  # @return [String] the JSON `gh api --paginate --slurp` prints for it
  def answer(argv, pull)
    pull &&= JSON.parse(JSON.generate(pull))
    path = argv.last.to_s
    body = pull_body(path, pull) || (pull ? checks_body(path, pull) : [])
    JSON.generate(body)
  end

  def pull_body(path, pull)
    return [pull ? [rest_pull(pull)] : []] if path.include?("pulls?state=all")
    return [commits(pull)] if path.include?("/commits?")

    [Array(pull["comments"]).map { |comment| { "body" => comment["body"] } }] if path.include?("/comments")
  end

  def commits(pull)
    Array(pull["commits"]).map { |commit| { "sha" => commit["oid"], "commit" => { "message" => commit["messageHeadline"] } } }
  end

  def checks_body(path, pull)
    contexts, runs = Array(pull["statusCheckRollup"]).partition { |entry| entry.key?("state") || entry.key?("context") }
    return [{ "check_runs" => runs.map { |entry| check_run(entry) } }] if path.include?("/check-runs")

    [{ "statuses" => contexts.map { |entry| status(entry) } }]
  end

  # A `gh` for the board's reader: answers its REST reads of the open pull requests from `listing`,
  # which answers rows in the shape `gh pr list --json` gave, and hands any other read to
  # `otherwise`.
  #
  # @param listing [#call] answers the rows (and may raise)
  # @param otherwise [#call, nil] answers every other `gh` read
  def open_gh(listing, otherwise = nil)
    lambda do |*args|
      path = args.last.to_s
      next({}) if args[1] == "rate_limit"
      next listing.call.map { |row| open_rest(row) } if path.include?("pulls?state=open")
      next open_checks(listing.call, path) if path.include?("/commits/")

      otherwise&.call(*args)
    end
  end

  def open_rest(row)
    { "number" => row["number"], "state" => "open", "head" => { "ref" => row["headRefName"], "sha" => "sha-#{row["number"]}" },
      "created_at" => row["createdAt"] }
  end

  def open_checks(rows, path)
    row = rows.find { |candidate| path.include?("sha-#{candidate["number"]}/") }
    checks_body(path, "statusCheckRollup" => Array(row && row["statusCheckRollup"]))
  end

  def rest_pull(pull)
    merged = pull["state"] == "MERGED"
    { "number" => pull["number"], "state" => pull["state"] == "OPEN" ? "open" : "closed", "html_url" => pull["url"],
      "head" => { "ref" => pull["headRefName"], "sha" => SHA }, "created_at" => pull["createdAt"],
      "merged_at" => (merged ? "2026-01-01T00:00:00Z" : nil), "merge_commit_sha" => pull.dig("mergeCommit", "oid") }
  end

  def check_run(entry)
    { "name" => entry["name"], "status" => entry["status"].to_s.downcase, "conclusion" => entry["conclusion"].to_s.downcase,
      "details_url" => entry["detailsUrl"] }
  end

  def status(entry)
    { "context" => entry["context"], "state" => entry["state"].to_s.downcase, "target_url" => entry["targetUrl"] }
  end
end
