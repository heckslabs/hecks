require "json"
require "open3"

# What the change-review specs drive: a scratch git checkout whose branch changed the paths an
# example names, a change review of its tip, and the architect's closing verdict on that review.
module ChangeReviewHelpers
  def launch(*argv) = Hecks::Adapters::Driving::CliRunner.call(runtime: @hecks, argv: argv, program: "hecks")

  # @param paths [Array<String>] the files the branch adds
  # @return [String] the branch's tip
  def branch_changing(*paths)
    git("init", "-q", "-b", "main")
    commit("README.md")
    git("switch", "-q", "-c", "w-change")
    paths.each { |path| commit(path) }
    git("rev-parse", "HEAD").strip
  end

  def consider(sha, work: "w-change")
    launch("agents", "ChangeReview.consider!", "review.value=#{sha}", "work.value=#{work}",
           "checkout.value=#{scratch}", "--wait")
  end

  def architect_closes(review, verdict)
    state = { state: "done", detail: "reviewed", output: { result: verdict } }
    File.write(File.join(scratch, "jobs", "stand-in-session", "state.json"), JSON.generate(state))
    launch("agent_run.check!", "to=#{review}", "--wait")
  end

  # @return [Hash, nil] the review's row as `ChangeReview.reviews` lists it
  def change_review(review) = rows("ChangeReview.reviews").find { |row| row["review"] == review }

  # @return [Hash, nil] the judged verdict the review sent to its coder
  def verdict_for(review) = rows("Verdict.judged").find { |row| row["run"] == review }

  def plan_review(run) = rows("PlanReview.reviews").find { |row| row["run"] == run }

  private

  def rows(query)
    out, = launch("agents", query)
    JSON.parse(out.to_s[/\[.*\]/m] || "[]")
  end

  def commit(path)
    full = File.join(scratch, path)
    FileUtils.mkdir_p(File.dirname(full))
    File.write(full, "#{path}\n")
    git("add", path)
    git("-c", "user.name=spec", "-c", "user.email=spec@example.invalid", "commit", "-q", "-m", path)
  end

  def git(*) = Open3.capture2("git", "-C", scratch, *).first
end
