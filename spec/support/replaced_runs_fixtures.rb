# Builders for the runs and checks a fake GitHub holds.
module ReplacedRunsFixtures
  TIP = "2d8d59d8e2".freeze

  def run(id, created, sha = TIP, workflow: "CI")
    { "databaseId" => id, "workflowName" => workflow, "event" => "pull_request", "headSha" => sha, "createdAt" => created }
  end

  def tip = TIP

  def old_run = run(1, "2026-11-11T20:21:21Z")

  def new_run = run(2, "2026-11-11T21:29:37Z")

  def check(run_id, status: "COMPLETED", conclusion: "SUCCESS")
    { "name" => "job#{run_id}", "status" => status, "conclusion" => conclusion,
      "detailsUrl" => "https://github.com/o/r/actions/runs/#{run_id}/job/9" }
  end

  def ghost = check(1, status: "QUEUED", conclusion: "")

  def names(rollup) = rollup.map { |entry| entry["name"] }
end
